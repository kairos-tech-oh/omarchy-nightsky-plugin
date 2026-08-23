import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "SkyMath.js" as SkyMath
import "Sanitise.js" as Sanitise

// Night Sky panel: where the location lives, where the Sun and Moon numbers are
// worked out, and where the chart is mounted.
//
// The sky itself never touches the network. Star, constellation, Milky Way and
// planetary data are bundled and every position is computed in SkyMath.js, so
// the chart draws correctly on a machine that has been offline for a week. The
// only three requests this plugin can make are location-related, and each is
// described at the Process that issues it.
Panel {
  id: root
  moduleName: "kairos.night-sky"
  ipcTarget: "kairos.night-sky"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false
  property bool settingsOpen: false

  // ---------------------------------------------------------------- location
  property bool locationReady: false
  property real latitude: 0
  property real longitude: 0
  property string locationLabel: "Location unavailable"
  property bool manualOverride: false
  property bool hasError: false
  property string errorText: ""

  // Seconds east of UTC for the place being shown, or NaN when unknown. The IP
  // lookup supplies it directly; a searched place needs the one extra request
  // that fetchTimezone() makes.
  property real placeOffsetSec: NaN
  property string placeZoneName: ""

  // ------------------------------------------------------------------ search
  property string searchInput: ""
  property var searchResults: []
  property bool searching: false
  property string searchNotice: ""
  // The query the current results belong to. Nominatim's policy requires
  // repeated identical queries to be answered from cache rather than re-sent.
  property string cachedQuery: ""
  property bool searchQueued: false
  property real lastNominatimMs: 0

  // ------------------------------------------------------------------- clock
  // Ticks so the bar label, the countdown and the chart all advance. Thirty
  // seconds is plenty: the sky turns a quarter of a degree per minute, which is
  // half a pixel on this chart, and clock times are shown to the minute.
  property real nowMs: Date.now()

  // Byte ceilings for each response, sized from measured replies: ipwho.is
  // returned 963 bytes, Nominatim 3.0 KiB at limit=5, and Open-Meteo 180 bytes
  // for a bare timezone lookup. 64 KiB is at least twenty times the largest of
  // those and is still a hard bound on what the shell can be made to hold.
  readonly property int locationCapBytes: 65536
  readonly property int searchCapBytes: 65536
  readonly property int timezoneCapBytes: 65536

  // Nominatim's usage policy sets an absolute ceiling of one request per
  // second. 1,100 ms leaves headroom for timer jitter without ever crossing it.
  readonly property int nominatimMinGapMs: 1100

  // Sent as the User-Agent on the Nominatim request, which the policy requires
  // to identify the application -- a stock library User-Agent is explicitly not
  // acceptable there.
  readonly property string userAgent:
      "omarchy-night-sky/1.0.0 (+https://github.com/kairos-tech-oh/omarchy-nightsky-plugin)"

  // ---------------------------------------------------------------- settings
  readonly property int magnitudeLimit: Math.min(6, Math.max(3, parseInt(setting("magnitudeLimit", 5), 10) || 5))
  readonly property bool showConstellationLines: setting("showConstellationLines", "yes") !== "no"
  readonly property bool showConstellationNames: setting("showConstellationNames", "yes") !== "no"
  readonly property bool showPlanets: setting("showPlanets", "yes") !== "no"
  readonly property bool showMilkyWay: setting("showMilkyWay", "yes") !== "no"
  readonly property bool use12Hour: setting("timeFormat", "24h") === "12h"

  // ------------------------------------------------------- derived astronomy
  // Bound to nowMs and the location, so everything downstream updates on the
  // clock tick or the moment a new place is chosen. A full recomputation is a
  // few microseconds, far cheaper than caching it would be to get right.
  readonly property var sunToday: root.locationReady
      ? SkyMath.sunTimes(root.nowMs, root.latitude, root.longitude) : null
  readonly property var nextEvent: root.locationReady
      ? SkyMath.nextSunEvent(root.nowMs, root.latitude, root.longitude) : null
  readonly property var moonNow: SkyMath.moonIllumination(SkyMath.julianDayFromMs(root.nowMs))

  // ------------------------------------------------------------- bar surface
  //
  // `label` and `tooltip` are the two strings that leave this plugin for text
  // sinks it does not own: the shell renders both through components that set
  // no textFormat and therefore default to Qt's Text.AutoText
  // (Ui/WidgetButton.qml and plugins/bar/Bar.qml). Both are wrapped in
  // plainOneLine() wholesale rather than field by field, so a part added to
  // either of them later is covered without anyone having to remember.
  //
  // Today every piece of `label` is a plugin-authored constant or a formatted
  // number, and only `tooltip` carries remote text. The wrapper is on both
  // anyway -- the point is that the boundary is guarded, not that the current
  // contents happen to be safe.
  readonly property string label: root.plainOneLine(root.composeLabel(), 40)

  function composeLabel() {
    if (!root.locationReady) return "SKY --"
    if (!root.nextEvent || root.nextEvent.kind === null) {
      // No sunrise or sunset today. Which of the two polar states we are in
      // decides the glyph -- printing a blank for both would be a lie.
      if (root.nextEvent && root.nextEvent.polar === "day") return "☀ 24h"
      if (root.nextEvent && root.nextEvent.polar === "night") return "☾ 24h"
      return "SKY --"
    }
    var arrow = root.nextEvent.kind === "sunrise" ? "↑" : "↓"
    return arrow + " " + root.formatClock(root.nextEvent.atMs, NaN)
  }

  readonly property string tooltip: root.plainOneLine(root.composeTooltip(), 200)

  function composeTooltip() {
    if (root.hasError && !root.locationReady) return "Night Sky: " + root.errorText
    if (!root.locationReady) return "Night Sky: locating…"

    var parts = []
    if (root.nextEvent && root.nextEvent.kind !== null) {
      parts.push((root.nextEvent.kind === "sunrise" ? "Sunrise " : "Sunset ")
          + root.formatClock(root.nextEvent.atMs, NaN)
          + " (" + root.relativeToNow(root.nextEvent.atMs) + ")")
    } else if (root.nextEvent && root.nextEvent.polar === "day") {
      parts.push("Midnight sun — the Sun does not set today")
    } else if (root.nextEvent && root.nextEvent.polar === "night") {
      parts.push("Polar night — the Sun does not rise today")
    }
    if (root.moonNow) {
      parts.push(root.moonNow.name + " " + Math.round(root.moonNow.fraction * 100) + "%")
    }
    parts.push(root.locationLabel)
    return parts.join(" · ")
  }

  // ------------------------------------------------------- panel plumbing
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    setCenterHoverRevealSuppressed(true)
    root.controller.show()
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && root.bar.shell && typeof root.bar.shell.focusAdjacentPanel === "function")
      root.bar.shell.focusAdjacentPanel(root.barIdentity, direction)
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  // --------------------------------------------------------------- sanitising
  // Everything that leaves this plugin for a text sink it does not own goes
  // through here. The rules, and why each removal is needed, are in
  // Sanitise.js, which is a separate file so the behaviour can be tested
  // directly against the reviewers' injection payload under both engines.
  function plainOneLine(value, maxLength) {
    return Sanitise.plainOneLine(value, maxLength)
  }

  // ------------------------------------------------------------ time display
  // Renders one instant as a wall clock.
  //
  // `offsetSec` selects whose clock: NaN means the user's own system timezone,
  // which is what the primary times use. A finite offset means the searched
  // location's clock, and is read off the shifted instant in UTC so the host's
  // own DST rules cannot leak into another country's time.
  function formatClock(ms, offsetSec) {
    if (ms === null || ms === undefined || !isFinite(ms)) return "--:--"
    var hours
    var minutes
    if (isFinite(offsetSec)) {
      var shifted = new Date(ms + offsetSec * 1000)
      hours = shifted.getUTCHours()
      minutes = shifted.getUTCMinutes()
    } else {
      var local = new Date(ms)
      hours = local.getHours()
      minutes = local.getMinutes()
    }
    var suffix = ""
    if (root.use12Hour) {
      suffix = hours < 12 ? " AM" : " PM"
      hours = hours % 12
      if (hours === 0) hours = 12
    }
    var paddedHours = root.use12Hour ? String(hours) : (hours < 10 ? "0" + hours : String(hours))
    var paddedMinutes = minutes < 10 ? "0" + minutes : String(minutes)
    return paddedHours + ":" + paddedMinutes + suffix
  }

  // "UTC+9", "UTC-4", "UTC+5:30" -- offsets are not all whole hours.
  function formatOffset(offsetSec) {
    if (!isFinite(offsetSec)) return ""
    var totalMinutes = Math.round(offsetSec / 60)
    var sign = totalMinutes < 0 ? "-" : "+"
    totalMinutes = Math.abs(totalMinutes)
    var hours = Math.floor(totalMinutes / 60)
    var minutes = totalMinutes % 60
    return "UTC" + sign + hours + (minutes === 0 ? "" : ":" + (minutes < 10 ? "0" + minutes : minutes))
  }

  // The host's own current offset from UTC, in seconds east.
  function userOffsetSec() {
    return -new Date(root.nowMs).getTimezoneOffset() * 60
  }

  // True when the shown place keeps a different clock than the user does, which
  // is the only case where a second line earns its space.
  function showsForeignClock() {
    if (!isFinite(root.placeOffsetSec)) return false
    return Math.abs(root.placeOffsetSec - root.userOffsetSec()) > 60
  }

  // A second line for a sun event, in the location's own clock. Empty when the
  // place keeps the same time as the user, so the common case stays uncluttered.
  function foreignClockLine(ms) {
    if (!root.showsForeignClock() || ms === null || !isFinite(ms)) return ""
    return root.formatClock(ms, root.placeOffsetSec) + " local"
        + (root.placeZoneName !== "" ? ", " + root.placeZoneName : "")
        + " · " + root.formatOffset(root.placeOffsetSec)
  }

  function relativeToNow(ms) {
    if (ms === null || !isFinite(ms)) return ""
    var minutes = Math.round((ms - root.nowMs) / 60000)
    if (minutes <= 0) return "now"
    if (minutes < 60) return "in " + minutes + " min"
    var hours = Math.floor(minutes / 60)
    var remainder = minutes % 60
    if (hours < 24) return "in " + hours + "h" + (remainder > 0 ? " " + remainder + "m" : "")
    return "in " + Math.floor(hours / 24) + "d"
  }

  function dayLengthLabel() {
    if (!root.sunToday) return ""
    if (root.sunToday.polar === "day") return "Sun up all day"
    if (root.sunToday.polar === "night") return "Sun below the horizon all day"
    if (root.sunToday.sunriseMs === null || root.sunToday.sunsetMs === null) return ""
    var minutes = Math.round((root.sunToday.sunsetMs - root.sunToday.sunriseMs) / 60000)
    return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m of daylight"
  }

  // ------------------------------------------------------------- networking
  // Bounded fetch, identical in shape to the one the flight-tracker plugin uses
  // and for the same reasons.
  //
  //   head -c   closes the pipe at the byte ceiling, at the producer, so an
  //             oversized body is never held in the shell's memory. A check
  //             after StdioCollector has read the stream would be too late --
  //             the allocation has already happened by then.
  //   timeout   is the deadline that still applies while curl is blocked in a
  //             syscall; curl's own --max-time is the inner limit.
  //
  // cap+1 bytes are requested so a body sitting exactly at the ceiling stays
  // distinguishable from one that was cut off. The URL and every option travel
  // as argv entries -- nothing is spliced into the script text.
  function cappedCurl(url, capBytes, maxTimeSec, extraArgs) {
    // timeout 0 means *no limit*, so a computed deadline that reaches zero
    // would quietly switch the ceiling off. Clamp both bounds to at least 1.
    var innerSec = Math.max(1, Math.round(maxTimeSec))
    var deadlineSec = Math.max(1, innerSec + 5)
    var command = ["timeout", "-k", "2", String(deadlineSec),
                   "sh", "-c", 'cap="$1"; shift; curl "$@" | head -c "$cap"', "sh",
                   String(capBytes + 1),
                   "-fsSL", "--max-time", String(innerSec)]
    if (extraArgs) command = command.concat(extraArgs)
    return command.concat(["--", String(url)])
  }

  // curl's exit status does not survive that pipeline -- head exits 0 whether
  // curl succeeded, 404'd, or was killed at the deadline -- so an empty body is
  // what reports producer failure. The length check is only a secondary guard:
  // String.length counts UTF-16 units rather than bytes, and head -c is the
  // bound that actually holds.
  function parseCappedJson(raw, capBytes) {
    var text = String(raw || "")
    if (text.trim() === "") throw new Error("empty response")
    if (text.length > capBytes) throw new Error("response exceeded " + capBytes + " bytes")
    return JSON.parse(text)
  }

  function fetchLocation() {
    if (root.manualOverride || locationProcess.running) return
    locationProcess.running = true
  }

  // Search, subject to Nominatim's one-request-per-second ceiling.
  //
  // Three separate things keep this inside the policy:
  //   - it only ever runs from Enter or the Search button, never per keystroke,
  //     which the policy forbids outright for auto-complete;
  //   - an identical repeat query is answered from the results already in hand
  //     rather than re-sent, which the policy requires;
  //   - and anything arriving sooner than nominatimMinGapMs after the last
  //     request is queued rather than dropped or sent. A single queued flag and
  //     a single timer mean ten frantic clicks collapse into one request.
  function searchLocation() {
    var query = String(root.searchInput || "").trim()
    if (query === "") return
    if (searchProcess.running) return

    if (query === root.cachedQuery && root.searchResults.length > 0) {
      root.searchNotice = "Showing the results already fetched for that search."
      return
    }

    var sinceLast = Date.now() - root.lastNominatimMs
    if (root.lastNominatimMs > 0 && sinceLast < root.nominatimMinGapMs) {
      root.searchQueued = true
      searchGate.interval = Math.max(1, root.nominatimMinGapMs - sinceLast)
      searchGate.restart()
      root.searchNotice = "Waiting a moment — OpenStreetMap allows one search per second."
      return
    }

    root.searchQueued = false
    root.searching = true
    root.searchNotice = ""
    root.searchResults = []
    root.lastNominatimMs = Date.now()
    root.cachedQuery = query
    searchProcess.command = root.cappedCurl(
        "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=5&q="
            + encodeURIComponent(query),
        root.searchCapBytes, 20, ["-A", root.userAgent])
    searchProcess.running = true
  }

  function selectPlace(result) {
    var nextLatitude = Number(result.lat)
    var nextLongitude = Number(result.lon)
    if (!isFinite(nextLatitude) || !isFinite(nextLongitude)) return
    if (Math.abs(nextLatitude) > 90 || Math.abs(nextLongitude) > 180) return

    root.latitude = nextLatitude
    root.longitude = nextLongitude
    root.locationLabel = root.plainOneLine(result.display_name || "Selected place", 120)
    root.locationReady = true
    root.manualOverride = true
    root.hasError = false
    root.searchResults = []
    root.searchNotice = ""
    root.searching = false
    root.searchInput = ""
    root.cachedQuery = ""

    // The new place's clock is unknown until the one timezone request returns.
    root.placeOffsetSec = NaN
    root.placeZoneName = ""
    root.fetchTimezone()
  }

  // One request, only ever on choosing a search result -- never on a timer and
  // never on a redraw. Its answer is kept with the location, so re-opening the
  // panel costs nothing.
  //
  // Sunrise and sunset are deliberately NOT taken from here even though this
  // endpoint offers them: computing them locally means they stay correct
  // offline and update the instant the location changes. All this call supplies
  // is the UTC offset, which cannot be derived from coordinates alone.
  function fetchTimezone() {
    if (timezoneProcess.running) return
    if (!root.locationReady) return
    timezoneProcess.command = root.cappedCurl(
        "https://api.open-meteo.com/v1/forecast?latitude=" + root.latitude.toFixed(4)
            + "&longitude=" + root.longitude.toFixed(4) + "&timezone=auto",
        root.timezoneCapBytes, 15)
    timezoneProcess.running = true
  }

  function useCurrentLocation() {
    root.manualOverride = false
    root.locationReady = false
    root.placeOffsetSec = NaN
    root.placeZoneName = ""
    root.searchResults = []
    root.searchNotice = ""
    root.cachedQuery = ""
    root.fetchLocation()
  }

  // Persists one settings key through the shell's own config store and mirrors
  // it locally, so the readonly properties above pick it up without waiting for
  // the round trip. Every one of these settings is a pure redraw -- none of
  // them can cause a network request.
  function updateSetting(key, value) {
    var merged = Object.assign({}, root.settings || {})
    merged[key] = value
    root.settings = merged
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, merged)
  }

  function toggleSetting(key) {
    root.updateSetting(key, root.setting(key, "yes") === "no" ? "yes" : "no")
  }

  function adjustMagnitude(delta) {
    root.updateSetting("magnitudeLimit", Math.min(6, Math.max(3, root.magnitudeLimit + delta)))
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.openFromHotkey() }
    function close() { root.close() }
    function show() { root.openFromHotkey() }
    function hide() { root.close() }
    function refresh() { root.useCurrentLocation(); return "ok" }
    function toggle() { root.toggle() }
  }

  // Approximate location from the caller's IP address. ipwho.is needs no key
  // and allows 1,000 requests a day per address; this runs once at startup and
  // then every six hours, which is about five a day.
  Process {
    id: locationProcess
    command: root.cappedCurl("https://ipwho.is/", root.locationCapBytes, 15)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var location = root.parseCappedJson(text, root.locationCapBytes)
          var nextLatitude = Number(location.latitude)
          var nextLongitude = Number(location.longitude)
          if (!location.success || !isFinite(nextLatitude) || !isFinite(nextLongitude))
            throw new Error("location unavailable")
          if (Math.abs(nextLatitude) > 90 || Math.abs(nextLongitude) > 180)
            throw new Error("location out of range")

          root.latitude = nextLatitude
          root.longitude = nextLongitude
          // Sanitised at ingestion, so every downstream consumer -- including
          // the shell tooltip this plugin cannot configure -- gets safe text.
          root.locationLabel = root.plainOneLine(
              (location.city || "Unknown city") + ", "
                  + (location.country || "Unknown country"), 80)
          root.locationReady = true
          root.hasError = false

          // ipwho.is reports the zone with DST already applied, so the IP path
          // needs no separate timezone request at all.
          if (location.timezone && isFinite(Number(location.timezone.offset))) {
            root.placeOffsetSec = Number(location.timezone.offset)
            root.placeZoneName = root.plainOneLine(location.timezone.id || "", 60)
          } else {
            root.placeOffsetSec = NaN
            root.placeZoneName = ""
          }
        } catch (error) {
          // A failed refresh must not blank a location we already have: the
          // sky and the sun times stay correct from the last good fix.
          if (!root.locationReady) {
            root.hasError = true
            root.errorText = "Location unavailable"
          }
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.locationReady) {
        root.hasError = true
        root.errorText = "Location unavailable"
      }
    }
  }

  // Place search. See searchLocation() for how the one-per-second ceiling is
  // kept; this end only parses and bounds the answer.
  Process {
    id: searchProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var results = root.parseCappedJson(text, root.searchCapBytes)
          if (!Array.isArray(results)) results = []
          // Bound what QML retains independently of what the producer sent.
          // limit=5 is a request, not a guarantee.
          root.searchResults = results.slice(0, 5)
          root.searchNotice = root.searchResults.length === 0 ? "No places matched that search." : ""
        } catch (error) {
          root.searchResults = []
          root.cachedQuery = ""
          root.searchNotice = "Search is unavailable right now."
        }
        root.searching = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.searchResults = []
        root.cachedQuery = ""
        root.searchNotice = "Search is unavailable right now."
        root.searching = false
      }
    }
  }

  // UTC offset for a searched place. Fires once per selection.
  Process {
    id: timezoneProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var zone = root.parseCappedJson(text, root.timezoneCapBytes)
          var offset = Number(zone.utc_offset_seconds)
          // Real offsets run from UTC-12 to UTC+14.
          if (!isFinite(offset) || Math.abs(offset) > 14 * 3600) throw new Error("bad offset")
          root.placeOffsetSec = offset
          root.placeZoneName = root.plainOneLine(zone.timezone || "", 60)
        } catch (error) {
          // Not worth an error banner. Without an offset the panel simply drops
          // the secondary local-time line; the primary times, which are in the
          // user's own clock, are unaffected.
          root.placeOffsetSec = NaN
          root.placeZoneName = ""
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.placeOffsetSec = NaN
        root.placeZoneName = ""
      }
    }
  }

  // Releases a search that arrived inside the one-per-second window.
  Timer {
    id: searchGate
    repeat: false
    onTriggered: {
      if (root.searchQueued) root.searchLocation()
    }
  }

  // Location at startup, then every six hours. An IP-derived position does not
  // move, so anything more frequent would be requests spent on nothing.
  Timer {
    interval: 1
    running: true
    repeat: false
    onTriggered: root.fetchLocation()
  }

  Timer {
    interval: 6 * 60 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.fetchLocation()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          // ------------------------------------------------------- header
          Row {
            width: parent.width
            spacing: Style.space(8)

            Column {
              width: parent.width - settingsButton.width - parent.spacing
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "NIGHT SKY"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.locationReady
                    ? "Looking up from " + root.locationLabel
                    : (root.hasError ? root.errorText : "Locating…")
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Button {
              id: settingsButton
              text: root.settingsOpen ? "⚙ Close" : "⚙ Settings"
              implicitWidth: Style.space(84)
              implicitHeight: Style.space(30)
              onClicked: root.settingsOpen = !root.settingsOpen

              background: Rectangle {
                color: root.settingsOpen ? Qt.darker(root.bar.foreground, 4) : "transparent"
                border.color: root.bar.foreground
                border.width: 1
                radius: Style.space(4)
              }
            }
          }

          // -------------------------------------------------------- chart
          // The catalogue is a 190 KiB JavaScript library, and this Loader is
          // what keeps it out of the shell until it is wanted: `active` only
          // becomes true the first time the panel is opened. Once loaded it
          // stays loaded, because re-parsing it on every open would be a
          // visible stall for no gain.
          Item {
            id: chartSlot
            width: parent.width
            height: width
            visible: skyLoader.active

            // Latches true on the first open and never goes back. Binding the
            // Loader to root.opened directly would unload the chart -- and drop
            // the parsed catalogue -- every time the panel closed, then stall
            // on the next open re-parsing it.
            property bool everOpened: false

            Loader {
              id: skyLoader
              anchors.fill: parent
              active: chartSlot.everOpened
              source: Qt.resolvedUrl("SkyChart.qml")

              onLoaded: {
                item.bar = Qt.binding(function() { return root.bar })
                item.latitude = Qt.binding(function() { return root.latitude })
                item.longitude = Qt.binding(function() { return root.longitude })
                item.epochMs = Qt.binding(function() { return root.nowMs })
                item.ready = Qt.binding(function() { return root.locationReady })
                item.magnitudeLimit = Qt.binding(function() { return root.magnitudeLimit })
                item.showLines = Qt.binding(function() { return root.showConstellationLines })
                item.showNames = Qt.binding(function() { return root.showConstellationNames })
                item.showBodies = Qt.binding(function() { return root.showPlanets })
                item.showMilkyWay = Qt.binding(function() { return root.showMilkyWay })
              }
            }

            Connections {
              target: root
              function onOpenedChanged() {
                if (root.opened) chartSlot.everOpened = true
              }
            }

            Component.onCompleted: if (root.opened) chartSlot.everOpened = true
          }

          // ------------------------------------------------- sun and moon
          Row {
            width: parent.width
            spacing: Style.space(12)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "SUNRISE"
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: root.sunToday && root.sunToday.polar === "day" ? "—"
                    : (root.sunToday && root.sunToday.polar === "night" ? "—"
                    : root.formatClock(root.sunToday ? root.sunToday.sunriseMs : null, NaN))
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: text !== ""
                text: root.sunToday ? root.foreignClockLine(root.sunToday.sunriseMs) : ""
                color: Qt.darker(root.bar.foreground, 1.35)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "SUNSET"
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: root.sunToday && root.sunToday.polar !== null ? "—"
                    : root.formatClock(root.sunToday ? root.sunToday.sunsetMs : null, NaN)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: text !== ""
                text: root.sunToday ? root.foreignClockLine(root.sunToday.sunsetMs) : ""
                color: Qt.darker(root.bar.foreground, 1.35)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: {
              var pieces = []
              var daylight = root.dayLengthLabel()
              if (daylight !== "") pieces.push(daylight)
              if (root.nextEvent && root.nextEvent.kind !== null) {
                pieces.push((root.nextEvent.kind === "sunrise" ? "Sunrise " : "Sunset ")
                    + root.relativeToNow(root.nextEvent.atMs))
              }
              if (root.moonNow) {
                pieces.push(root.moonNow.name + " · "
                    + Math.round(root.moonNow.fraction * 100) + "% lit")
              }
              return pieces.join(" · ")
            }
            color: Qt.darker(root.bar.foreground, 1.25)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.showsForeignClock()
            text: "Times above are on your clock. This place keeps "
                + root.formatOffset(root.placeOffsetSec) + "."
            color: Qt.darker(root.bar.foreground, 1.35)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          // ----------------------------------------------------- settings
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.settingsOpen

            Text {
              textFormat: Text.PlainText
              text: "SETTINGS"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: Style.space(150)
                text: "Faintest magnitude"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: magnitudeDown
                text: "−"
                implicitWidth: Style.space(30)
                implicitHeight: Style.space(30)
                enabled: root.magnitudeLimit > 3
                onClicked: root.adjustMagnitude(-1)
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: magnitudeDown.enabled ? 1.0 : 0.45
                }
              }

              Text {
                textFormat: Text.PlainText
                width: Style.space(40)
                text: root.magnitudeLimit.toFixed(1)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: magnitudeUp
                text: "+"
                implicitWidth: Style.space(30)
                implicitHeight: Style.space(30)
                enabled: root.magnitudeLimit < 6
                onClicked: root.adjustMagnitude(1)
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: magnitudeUp.enabled ? 1.0 : 0.45
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: [
                  { key: "showConstellationLines", label: "Lines" },
                  { key: "showConstellationNames", label: "Names" },
                  { key: "showPlanets", label: "Planets" },
                  { key: "showMilkyWay", label: "Milky Way" }
                ]

                Button {
                  id: toggleButton
                  required property var modelData
                  readonly property bool active: root.setting(modelData.key, "yes") !== "no"
                  text: modelData.label
                  implicitHeight: Style.space(30)
                  onClicked: root.toggleSetting(modelData.key)
                  background: Rectangle {
                    color: toggleButton.active ? Qt.darker(root.bar.foreground, 4) : "transparent"
                    border.color: root.bar.foreground
                    border.width: 1
                    radius: Style.space(4)
                    opacity: toggleButton.active ? 1.0 : 0.55
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Every setting here redraws the chart from data already on disk. "
                  + "None of them makes a network request."
              color: Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }

          // ----------------------------------------------------- location
          Column {
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "LOCATION"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.locationLabel + (root.manualOverride ? "" : " (IP approx.)")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.locationReady
                  ? root.latitude.toFixed(4) + ", " + root.longitude.toFixed(4)
                      + (root.placeZoneName !== "" ? " · " + root.placeZoneName : "")
                  : "Locating…"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              text: "SEARCH ANOTHER PLACE"
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            TextField {
              id: searchField
              width: parent.width
              placeholderText: "Type a place, then press Enter"
              text: root.searchInput
              // Only mirrors the text. The search itself runs from Enter or the
              // button below -- never from typing, because Nominatim's usage
              // policy forbids client-side auto-complete outright.
              onTextChanged: root.searchInput = text
              onAccepted: root.searchLocation()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                id: searchButton
                text: root.searching ? "⌕ …" : "⌕ Search"
                implicitHeight: Style.space(30)
                enabled: !root.searching
                onClicked: root.searchLocation()
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                  opacity: searchButton.enabled ? 1.0 : 0.45
                }
              }

              Button {
                id: currentButton
                text: "⌖ Use my location"
                implicitHeight: Style.space(30)
                visible: root.manualOverride
                onClicked: root.useCurrentLocation()
                background: Rectangle {
                  color: "transparent"
                  border.color: root.bar.foreground
                  border.width: 1
                  radius: Style.space(4)
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.searchNotice !== ""
              text: root.searchNotice
              color: Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Repeater {
              model: root.searchResults

              Item {
                required property var modelData
                width: contentColumn.width
                implicitHeight: resultText.implicitHeight + Style.space(8)

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectPlace(modelData)
                }

                Text {
                  id: resultText
                  // display_name is arbitrary text from a public database, so
                  // it is one of the strings this plugin most needs to keep out
                  // of Qt's rich-text path. Every Text here is PlainText for
                  // that reason, not only the ones carrying remote data.
                  textFormat: Text.PlainText
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(modelData.display_name || "")
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  maximumLineCount: 2
                  wrapMode: Text.Wrap
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Sky data bundled offline · Search © OpenStreetMap contributors"
              color: Qt.darker(root.bar.foreground, 1.45)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }
        }
      }
    }
  }
}
