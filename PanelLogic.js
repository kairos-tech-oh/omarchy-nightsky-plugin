.pragma library

// ------------------------------------------------------------ time display
// Renders one instant as a wall clock.
//
// `offsetSec` selects whose clock: NaN means the user's own system timezone,
// which is what the primary times use. A finite offset means the searched
// location's clock, and is read off the shifted instant in UTC so the host's
// own DST rules cannot leak into another country's time.
function formatClock(ms, offsetSec, use12Hour) {
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
  if (use12Hour) {
    suffix = hours < 12 ? " AM" : " PM"
    hours = hours % 12
    if (hours === 0) hours = 12
  }
  var paddedHours = use12Hour ? String(hours) : (hours < 10 ? "0" + hours : String(hours))
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
function userOffsetSec(nowMs) {
  return -new Date(nowMs).getTimezoneOffset() * 60
}

// True when the shown place keeps a different clock than the user does, which
// is the only case where a second line earns its space.
function showsForeignClock(placeOffsetSec, userOffset) {
  if (!isFinite(placeOffsetSec)) return false
  return Math.abs(placeOffsetSec - userOffset) > 60
}

// A second line for a sun event, in the location's own clock. Empty when the
// place keeps the same time as the user, so the common case stays uncluttered.
function foreignClockLine(ms, placeOffsetSec, placeZoneName, userOffset, use12Hour) {
  if (!showsForeignClock(placeOffsetSec, userOffset) || ms === null || !isFinite(ms)) return ""
  return formatClock(ms, placeOffsetSec, use12Hour) + " local"
      + (placeZoneName !== "" ? ", " + placeZoneName : "")
      + " · " + formatOffset(placeOffsetSec)
}

function relativeToNow(ms, nowMs) {
  if (ms === null || !isFinite(ms)) return ""
  var minutes = Math.round((ms - nowMs) / 60000)
  if (minutes <= 0) return "now"
  if (minutes < 60) return "in " + minutes + " min"
  var hours = Math.floor(minutes / 60)
  var remainder = minutes % 60
  if (hours < 24) return "in " + hours + "h" + (remainder > 0 ? " " + remainder + "m" : "")
  return "in " + Math.floor(hours / 24) + "d"
}

function dayLengthLabel(sunToday) {
  if (!sunToday) return ""
  if (sunToday.polar === "day") return "Sun up all day"
  if (sunToday.polar === "night") return "Sun below the horizon all day"
  if (sunToday.sunriseMs === null || sunToday.sunsetMs === null) return ""
  var minutes = Math.round((sunToday.sunsetMs - sunToday.sunriseMs) / 60000)
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
// No redirects are followed: every URL passed in here is a hardcoded https
// literal, so there is nothing to gain from chasing a 3xx, and a compromised
// or misconfigured endpoint can't use one to redirect the request to an
// internal or private origin.
//
// --proto "=https" pins the protocol on top of that. The `=` prefix is the
// whole point and is easy to lose: curl treats an unprefixed protocol name as
// *add to the permitted set*, so `--proto=https` -- which is the form that
// reads correctly -- permits everything curl already allowed and restricts
// nothing. Measured on curl 8.21.0: with `--proto=https`, both
// `http://example.com/` and `file:///etc/passwd` still succeed; with
// `--proto "=https"` curl refuses each with "Protocol ... is disabled".
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
                 "-fsS", "--proto", "=https", "--max-time", String(innerSec)]
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
