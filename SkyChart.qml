import QtQuick
import qs.Commons
import "SkyMath.js" as SkyMath
import "data/Catalog.js" as Catalog

// The all-sky chart: the whole visible hemisphere on one disc, zenith at the
// centre and the horizon on the rim.
//
// This file is loaded lazily -- importing it is what pulls the 190 KiB
// catalogue into the engine, so Panel.qml keeps it behind a Loader that stays
// inactive until someone actually opens the panel.
//
// Nothing here reaches the network. Every position is computed from the bundled
// catalogue by SkyMath.js at the instant given by `epochMs`.
Item {
  id: root

  property var bar: null
  property real latitude: 0
  property real longitude: 0
  property real epochMs: Date.now()
  property bool ready: false

  property int magnitudeLimit: 5
  property bool showLines: true
  property bool showNames: true
  property bool showBodies: true
  property bool showMilkyWay: true

  // Retention ceilings, re-checked here rather than trusted from the generator.
  // The catalogue is a JavaScript library in a directory under $HOME, so these
  // are belt-and-braces rather than a security boundary -- anything able to
  // rewrite it is already running code in the shell -- but a loop that cannot
  // run away is worth the two comparisons.
  readonly property int starLimit: Math.min(Catalog.STAR_COUNT, Catalog.MAX_STARS)

  // The sky is drawn dark in every theme. A night sky rendered on a light
  // background is not a night sky, and white-on-white stars are not visible at
  // any opacity. The theme's foreground still owns the frame, the cardinal
  // letters and the caption below, so the chart sits in its surroundings
  // without pretending to be part of them.
  readonly property color skyColour: "#070a12"
  readonly property color horizonColour: root.bar ? root.bar.foreground : "#d0d6e4"
  readonly property color lineColour: "#4d6ea8"
  readonly property color labelColour: "#7f93bb"
  readonly property color milkyWayColour: "#8ea6dd"

  // Objects the pointer can identify, rebuilt on every paint. Bounded by
  // construction: named stars in the catalogue, five planets and the Moon.
  property var hotspots: []
  property string hoverLabel: ""

  implicitHeight: width

  function scheduleRepaint() {
    if (canvas.available) canvas.requestPaint()
  }

  onLatitudeChanged: scheduleRepaint()
  onLongitudeChanged: scheduleRepaint()
  onEpochMsChanged: scheduleRepaint()
  onReadyChanged: scheduleRepaint()
  onMagnitudeLimitChanged: scheduleRepaint()
  onShowLinesChanged: scheduleRepaint()
  onShowNamesChanged: scheduleRepaint()
  onShowBodiesChanged: scheduleRepaint()
  onShowMilkyWayChanged: scheduleRepaint()

  // Exposed so the chart can be rendered and inspected outside omarchy-shell
  // (see tools/preview). Restarting the shell to look at a drawing change
  // takes down the user's bar, lock screen and polkit agent, and a chart
  // evaluated against a shell that might still hold the previous code is worse
  // than no evaluation at all.
  readonly property alias canvasItem: canvas

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    // Software image target, painted synchronously.
    //
    // An FBO target would tie a once-a-minute redraw to a GPU context inside a
    // long-lived shell process, for no gain at this size. Immediate keeps the
    // paint on the GUI thread, which is a measured 12 ms for the full 5,044
    // stars and less once the magnitude limit trims the loop -- unnoticeable
    // at a sixty-second cadence, and far easier to reason about than handing
    // canvas state to another thread.
    renderTarget: Canvas.Image
    renderStrategy: Canvas.Immediate

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()

      var size = Math.min(width, height)
      // The inset has to clear the cardinal letters, which are drawn outside
      // the rim. 14px left them clipped against the panel edge.
      var radius = size / 2 - 20
      var centreX = width / 2
      var centreY = height / 2
      if (radius <= 0) return

      var hotspots = []

      // The sky disc itself is drawn whether or not we have a location -- an
      // empty frame reads as "not ready", where a blank gap reads as broken.
      ctx.beginPath()
      ctx.arc(centreX, centreY, radius, 0, Math.PI * 2)
      ctx.fillStyle = root.skyColour
      ctx.fill()

      if (!root.ready) {
        root.drawFrame(ctx, centreX, centreY, radius)
        root.hotspots = []
        return
      }

      var jd = SkyMath.julianDayFromMs(root.epochMs)
      var lst = SkyMath.localSiderealTime(jd, root.longitude)
      var scale = radius / 190.0

      // Everything inside the disc is clipped to it, so a shape straddling the
      // horizon is cut by the rim instead of spilling across the panel.
      ctx.save()
      ctx.beginPath()
      ctx.arc(centreX, centreY, radius, 0, Math.PI * 2)
      ctx.clip()

      if (root.showMilkyWay) root.drawMilkyWay(ctx, lst, centreX, centreY, radius)
      if (root.showLines) root.drawConstellationLines(ctx, lst, centreX, centreY, radius, scale)
      root.drawStars(ctx, lst, centreX, centreY, radius, scale, hotspots)
      if (root.showBodies) root.drawBodies(ctx, jd, lst, centreX, centreY, radius, scale, hotspots)
      if (root.showNames) root.drawConstellationNames(ctx, lst, centreX, centreY, radius, scale)

      ctx.restore()

      root.drawFrame(ctx, centreX, centreY, radius)
      root.hotspots = hotspots
    }
  }

  // ------------------------------------------------------------- projection
  // RA/Dec straight to a point on the disc, or null when below the horizon.
  function place(raDeg, decDeg, lst, centreX, centreY, radius) {
    var horizontal = SkyMath.equatorialToHorizontal(raDeg, decDeg, lst, root.latitude)
    return SkyMath.projectToDisc(horizontal.altitude, horizontal.azimuth, centreX, centreY, radius)
  }

  // As above, but a point below the horizon is pulled onto the rim rather than
  // discarded. Filled shapes need this: dropping the sunk vertices of a polygon
  // leaves a hole with the wrong outline, whereas clamping keeps the ring
  // closed and lets the circular clip do the cutting.
  function placeClamped(raDeg, decDeg, lst, centreX, centreY, radius) {
    var horizontal = SkyMath.equatorialToHorizontal(raDeg, decDeg, lst, root.latitude)
    var altitude = Math.max(0, horizontal.altitude)
    return {
      point: SkyMath.projectToDisc(altitude, horizontal.azimuth, centreX, centreY, radius),
      above: horizontal.altitude >= 0
    }
  }

  // ------------------------------------------------------------- Milky Way
  function drawMilkyWay(ctx, lst, centreX, centreY, radius) {
    ctx.strokeStyle = "transparent"
    for (var layerIndex = 0; layerIndex < Catalog.MILKY_WAY.length; layerIndex++) {
      var layer = Catalog.MILKY_WAY[layerIndex]
      // Nested contours: each inner layer is brighter, and drawing them over
      // one another builds the gradient without needing a real gradient.
      ctx.fillStyle = root.milkyWayColour
      ctx.globalAlpha = 0.06 + layerIndex * 0.028

      for (var ringIndex = 0; ringIndex < layer.length; ringIndex++) {
        var ring = layer[ringIndex]
        var started = false
        var anyAbove = false

        ctx.beginPath()
        for (var i = 0; i < ring.length; i += 2) {
          var placed = root.placeClamped(ring[i], ring[i + 1], lst, centreX, centreY, radius)
          if (!placed.point) continue
          if (placed.above) anyAbove = true
          if (!started) {
            ctx.moveTo(placed.point.x, placed.point.y)
            started = true
          } else {
            ctx.lineTo(placed.point.x, placed.point.y)
          }
        }
        // A ring entirely below the horizon would otherwise collapse onto the
        // rim and paint a bright sliver along the horizon that is not there.
        if (started && anyAbove) {
          ctx.closePath()
          ctx.fill()
        }
      }
    }
    ctx.globalAlpha = 1.0
  }

  // -------------------------------------------------- constellation figures
  // Joins consecutive catalogue vertices along great circles rather than in
  // screen space. A straight screen line between two widely separated stars
  // bows away from where the figure actually runs, which is most obvious for
  // the long spans in Draco and Eridanus and near the rim, where the projection
  // stretches hardest.
  function drawConstellationLines(ctx, lst, centreX, centreY, radius, scale) {
    ctx.strokeStyle = root.lineColour
    ctx.lineWidth = Math.max(0.7, 0.9 * scale)
    ctx.globalAlpha = 0.75
    ctx.lineCap = "round"

    for (var c = 0; c < Catalog.CONSTELLATION_LINES.length; c++) {
      var figure = Catalog.CONSTELLATION_LINES[c]
      for (var s = 1; s < figure.length; s++) {
        var segment = figure[s]
        ctx.beginPath()
        var drawing = false

        for (var i = 0; i + 3 < segment.length; i += 2) {
          var ra1 = segment[i], dec1 = segment[i + 1]
          var ra2 = segment[i + 2], dec2 = segment[i + 3]
          var separation = SkyMath.angularSeparation(ra1, dec1, ra2, dec2)
          var steps = Math.max(1, Math.ceil(separation / 4.0))

          for (var step = 0; step <= steps; step++) {
            if (step === 0 && i > 0) continue
            var interpolated = root.interpolate(ra1, dec1, ra2, dec2, step / steps)
            var point = root.place(interpolated.ra, interpolated.dec, lst, centreX, centreY, radius)
            if (!point) {
              // The figure has crossed the horizon: end this stroke and start a
              // fresh one when it comes back up, rather than drawing a chord
              // straight across the disc.
              if (drawing) { ctx.stroke(); ctx.beginPath(); drawing = false }
              continue
            }
            if (!drawing) { ctx.moveTo(point.x, point.y); drawing = true }
            else ctx.lineTo(point.x, point.y)
          }
        }
        if (drawing) ctx.stroke()
      }
    }
    ctx.globalAlpha = 1.0
  }

  // Great-circle interpolation between two equatorial positions. Done as a
  // normalised blend of unit vectors, which needs no special case at the
  // RA wrap-around or near the poles.
  function interpolate(ra1, dec1, ra2, dec2, fraction) {
    var deg = Math.PI / 180.0
    var x1 = Math.cos(dec1 * deg) * Math.cos(ra1 * deg)
    var y1 = Math.cos(dec1 * deg) * Math.sin(ra1 * deg)
    var z1 = Math.sin(dec1 * deg)
    var x2 = Math.cos(dec2 * deg) * Math.cos(ra2 * deg)
    var y2 = Math.cos(dec2 * deg) * Math.sin(ra2 * deg)
    var z2 = Math.sin(dec2 * deg)

    var x = x1 + (x2 - x1) * fraction
    var y = y1 + (y2 - y1) * fraction
    var z = z1 + (z2 - z1) * fraction
    var length = Math.sqrt(x * x + y * y + z * z)
    if (length < 1e-12) return { ra: ra1, dec: dec1 }

    return {
      ra: Math.atan2(y / length, x / length) * 180.0 / Math.PI,
      dec: Math.asin(Math.max(-1, Math.min(1, z / length))) * 180.0 / Math.PI
    }
  }

  // ------------------------------------------------------------------ stars
  function drawStars(ctx, lst, centreX, centreY, radius, scale, hotspots) {
    var limit = root.magnitudeLimit

    // Named stars are held in parallel arrays sorted by catalogue index, and
    // the star loop walks that same order, so one advancing cursor matches
    // names to stars without a lookup per star.
    var nameCursor = 0

    for (var i = 0; i < root.starLimit; i++) {
      var offset = i * 4
      var magnitude = Catalog.STARS[offset + 2]
      // The catalogue is sorted brightest first, so the first star past the
      // limit is the last star worth testing.
      if (magnitude > limit) break

      while (nameCursor < Catalog.NAMED_INDEX.length && Catalog.NAMED_INDEX[nameCursor] < i) nameCursor++
      var hasName = nameCursor < Catalog.NAMED_INDEX.length && Catalog.NAMED_INDEX[nameCursor] === i

      var point = root.place(Catalog.STARS[offset], Catalog.STARS[offset + 1],
                            lst, centreX, centreY, radius)
      if (!point) continue

      // Apparent size falls with magnitude. The +0.75 floor keeps a
      // magnitude-at-the-limit star as a visible speck rather than nothing.
      var size = Math.max(0.55, ((limit - magnitude) * 0.42 + 0.75) * scale)

      ctx.beginPath()
      ctx.arc(point.x, point.y, size, 0, Math.PI * 2)
      ctx.fillStyle = SkyMath.starColour(Catalog.STARS[offset + 3])
      ctx.fill()

      // Only the genuinely bright stars get a glow and a hover target; every
      // named star in the catalogue would be several hundred hotspots and a
      // chart that looks like it is under water.
      if (magnitude < 1.6) {
        ctx.beginPath()
        ctx.arc(point.x, point.y, size * 2.6, 0, Math.PI * 2)
        ctx.globalAlpha = 0.16
        ctx.fill()
        ctx.globalAlpha = 1.0
      }

      if (hasName && magnitude <= 2.6) {
        hotspots.push({
          x: point.x, y: point.y,
          label: Catalog.NAMED_TEXT[nameCursor] + " · mag " + magnitude.toFixed(1)
        })
      }
    }
  }

  // -------------------------------------------------------- Moon and planets
  function drawBodies(ctx, jd, lst, centreX, centreY, radius, scale, hotspots) {
    var earth = null
    for (var e = 0; e < Catalog.PLANETS.length; e++) {
      if (Catalog.PLANETS[e].id === "ter") earth = Catalog.PLANETS[e]
    }

    if (earth) {
      for (var p = 0; p < Catalog.PLANETS.length; p++) {
        var planet = Catalog.PLANETS[p]
        if (planet.id === "ter") continue

        var position = SkyMath.planetPosition(planet, earth, jd)
        var point = root.place(position.ra, position.dec, lst, centreX, centreY, radius)
        if (!point) continue

        var size = Math.max(1.6, (2.9 - position.magnitude * 0.28) * scale)
        size = Math.min(size, 4.6 * scale)

        ctx.beginPath()
        ctx.arc(point.x, point.y, size, 0, Math.PI * 2)
        ctx.fillStyle = "#ffe9b8"
        ctx.fill()

        ctx.beginPath()
        ctx.arc(point.x, point.y, size * 2.2, 0, Math.PI * 2)
        ctx.globalAlpha = 0.18
        ctx.fill()
        ctx.globalAlpha = 1.0

        // The label is placed on the side facing the centre of the disc, not
        // above the dot. A centred label on a planet near the rim runs off the
        // edge and gets cut by the clip -- "Ven" instead of "Venus".
        ctx.fillStyle = "#e7d4a4"
        ctx.font = Math.round(9 * scale) + "px " + root.fontFamily()
        var towardCentre = point.x > centreX ? -1 : 1
        ctx.textAlign = towardCentre < 0 ? "right" : "left"
        ctx.fillText(planet.name,
                     point.x + towardCentre * (size + 4 * scale),
                     point.y + 3 * scale)

        hotspots.push({
          x: point.x, y: point.y,
          label: planet.name + " · mag " + position.magnitude.toFixed(1)
        })
      }
    }

    var moon = SkyMath.moonIllumination(jd)
    var moonPoint = root.place(moon.ra, moon.dec, lst, centreX, centreY, radius)
    if (moonPoint) {
      root.drawMoon(ctx, moonPoint.x, moonPoint.y, Math.max(4.5, 7.0 * scale),
                    moon.fraction, moon.waxing)
      hotspots.push({
        x: moonPoint.x, y: moonPoint.y,
        label: moon.name + " · " + Math.round(moon.fraction * 100) + "% lit"
      })
    }
  }

  // The Moon at its actual phase, rather than a generic dot.
  //
  // The disc is the unlit Moon; the lit region is bounded by the limb on one
  // side and the terminator on the other. The terminator projects to a half
  // ellipse whose width is r*(1-2k) -- zero at quarter phase, and crossing
  // through zero to bulge the other way past it, which is what turns a crescent
  // into a gibbous without a second code path.
  //
  // The lit side is drawn to the right when waxing and to the left when waning:
  // correct as seen from mid-northern latitudes. The true orientation depends
  // on where the Sun sits relative to the Moon on the chart, but at this size
  // -- a disc a few pixels across -- the tilt is below what is visible.
  function drawMoon(ctx, cx, cy, r, fraction, waxing) {
    var kappa = 0.5522847498
    var terminator = r * (1.0 - 2.0 * fraction)
    var direction = waxing ? 1 : -1

    ctx.beginPath()
    ctx.arc(cx, cy, r, 0, Math.PI * 2)
    ctx.fillStyle = "#2b3348"
    ctx.fill()

    ctx.beginPath()
    // Down the lit limb, a clean half circle.
    ctx.moveTo(cx, cy - r)
    ctx.bezierCurveTo(cx + direction * r * kappa, cy - r,
                      cx + direction * r, cy - r * kappa,
                      cx + direction * r, cy)
    ctx.bezierCurveTo(cx + direction * r, cy + r * kappa,
                      cx + direction * r * kappa, cy + r,
                      cx, cy + r)
    // Back up the terminator.
    ctx.bezierCurveTo(cx - direction * terminator * kappa, cy + r,
                      cx - direction * terminator, cy + r * kappa,
                      cx - direction * terminator, cy)
    ctx.bezierCurveTo(cx - direction * terminator, cy - r * kappa,
                      cx - direction * terminator * kappa, cy - r,
                      cx, cy - r)
    ctx.closePath()
    ctx.fillStyle = "#f2efe4"
    ctx.fill()
  }

  // ------------------------------------------------------------- name labels
  function drawConstellationNames(ctx, lst, centreX, centreY, radius, scale) {
    ctx.fillStyle = root.labelColour
    ctx.font = Math.round(10 * scale) + "px " + root.fontFamily()
    ctx.textAlign = "center"
    ctx.globalAlpha = 0.85

    for (var i = 0; i < Catalog.CONSTELLATIONS.length; i++) {
      var entry = Catalog.CONSTELLATIONS[i]
      // Rank 1 and 2 are the large, recognisable figures. Labelling all 89
      // fills the disc with text and hides the sky behind it.
      if (entry[4] > 2) continue

      var horizontal = SkyMath.equatorialToHorizontal(entry[2], entry[3], lst, root.latitude)
      // Kept clear of the horizon: a label right on the rim is mostly cut off
      // by the clip and unreadable anyway.
      if (horizontal.altitude < 8) continue

      var point = SkyMath.projectToDisc(horizontal.altitude, horizontal.azimuth,
                                        centreX, centreY, radius)
      if (!point) continue

      // Pull a label back inside the disc when its box would cross the rim.
      // Culling by altitude alone is not enough: "Canis Major" is a wide string
      // and overhangs the edge from a position that is comfortably above the
      // horizon, so the width has to be measured, not assumed.
      var half = ctx.measureText(entry[1]).width / 2 + 2
      var dx = point.x - centreX
      var dy = point.y - centreY
      var distance = Math.sqrt(dx * dx + dy * dy)
      var overflow = distance + half - (radius - 2)
      if (overflow > 0 && distance > 0.001) {
        point = {
          x: point.x - (dx / distance) * overflow,
          y: point.y - (dy / distance) * overflow
        }
      }

      ctx.fillText(entry[1], point.x, point.y)
    }
    ctx.globalAlpha = 1.0
  }

  // ------------------------------------------------------------------ frame
  function drawFrame(ctx, centreX, centreY, radius) {
    ctx.strokeStyle = root.horizonColour
    ctx.globalAlpha = 0.55
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.arc(centreX, centreY, radius, 0, Math.PI * 2)
    ctx.stroke()

    // A faint ring at 45 degrees altitude, the halfway mark between horizon and
    // zenith, so the chart carries some sense of height rather than being a
    // featureless field.
    ctx.globalAlpha = 0.18
    ctx.beginPath()
    ctx.arc(centreX, centreY, radius / 2, 0, Math.PI * 2)
    ctx.stroke()

    ctx.globalAlpha = 0.85
    ctx.fillStyle = root.horizonColour
    ctx.font = "bold " + Math.round(11) + "px " + root.fontFamily()
    ctx.textAlign = "center"

    // East is on the LEFT. That is how a sky chart works -- it is held up
    // overhead and read from underneath, so the compass runs the opposite way
    // round from a map of the ground.
    var margin = 9
    ctx.fillText("N", centreX, centreY - radius - margin + 4)
    ctx.fillText("S", centreX, centreY + radius + margin + 4)
    ctx.fillText("E", centreX - radius - margin, centreY + 4)
    ctx.fillText("W", centreX + radius + margin, centreY + 4)
    ctx.globalAlpha = 1.0
  }

  function fontFamily() {
    return root.bar && root.bar.fontFamily ? root.bar.fontFamily : "sans-serif"
  }

  // ------------------------------------------------------------------ hover
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton

    onPositionChanged: function(mouse) {
      var best = ""
      var bestDistance = 14 * 14
      for (var i = 0; i < root.hotspots.length; i++) {
        var spot = root.hotspots[i]
        var dx = spot.x - mouse.x
        var dy = spot.y - mouse.y
        var distance = dx * dx + dy * dy
        if (distance < bestDistance) {
          bestDistance = distance
          best = spot.label
        }
      }
      root.hoverLabel = best
    }

    onExited: root.hoverLabel = ""
  }

  // Hover readout. Sits over the bottom of the disc so it never changes the
  // panel's height as it appears and disappears.
  Rectangle {
    visible: root.hoverLabel !== ""
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    width: hoverText.implicitWidth + Style.space(14)
    height: hoverText.implicitHeight + Style.space(8)
    radius: Style.space(4)
    color: "#0d1220"
    border.color: root.lineColour
    border.width: 1
    opacity: 0.94

    Text {
      id: hoverText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: root.hoverLabel
      color: "#dce4f5"
      font.family: root.fontFamily()
      font.pixelSize: Style.font.bodySmall
    }
  }
}
