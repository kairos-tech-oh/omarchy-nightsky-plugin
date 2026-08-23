.pragma library

// Sanitising for text that crosses out of this plugin.
//
// Every Text element the plugin owns sets textFormat: Text.PlainText. That is
// necessary and not sufficient, because two of the sinks a bar widget writes to
// are not the plugin's to configure:
//
//   /usr/share/omarchy/shell/Ui/WidgetButton.qml   the bar label
//   /usr/share/omarchy/shell/plugins/bar/Bar.qml   the bar tooltip
//
// Neither sets textFormat anywhere, so both fall back to Qt's default
// Text.AutoText, which sniffs its input and renders it as HTML -- including
// <img src="http://..."> , which performs a network fetch from inside the
// shared shell process. Crossing that boundary is what a bar widget does, so it
// cannot be avoided; the string has to be safe before it goes.
//
// This lives in its own file so it can be tested directly, under both Node and
// Qt's V4 engine, against the payload the marketplace reviewers actually use.
// See tools/check-skymath.js and tools/check-qml-engine.qml.

// Collapses an untrusted string to a single safe line.
//
// Three removals, each for its own reason:
//
//   < >    no tag can survive without them
//   &      removing only the brackets still leaves &#60; and &lt;, which the
//          rich-text engine decodes back into a bracket. Taking the ampersand
//          closes the only route back.
//   ctrl   control characters and newlines, which let one value forge what
//          looks like a second line of the display
//
// Then whitespace is collapsed and the result length-capped, because a
// Nominatim display_name can run to several hundred characters and would paint
// a tooltip across the whole screen.
function plainOneLine(value, maxLength) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\x00-\x1f\x7f]/g, " ")
  text = text.replace(/[<>&]/g, "")
  text = text.replace(/\s+/g, " ")
  text = text.replace(/^\s+|\s+$/g, "")
  var limit = maxLength > 0 ? maxLength : 160
  return text.length > limit ? text.substring(0, limit - 1) + "…" : text
}
