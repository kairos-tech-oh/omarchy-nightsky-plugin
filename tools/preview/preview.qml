// Renders SkyChart.qml to a PNG outside omarchy-shell.
//
// Restarting the shell takes down the user's bar, lock screen and polkit agent,
// which is far too heavy a loop to iterate a drawing in -- and evaluating a
// chart against a shell that might still be running the previous code is how
// you end up certain of something that is not true. This harness loads the real
// SkyChart.qml, with the real catalogue and the real maths, against stub
// qs.Ui/qs.Commons modules, so the only thing not exercised is the shell
// chrome around it.
//
//     tools/preview/render.sh [isoTimestamp] [latitude] [longitude]
//
// Writes preview-sky.png next to itself.

import QtQuick
import QtQuick.Window

Window {
  id: window
  width: 460
  height: 460
  visible: true
  color: "#11141c"

  // render.sh passes these after a bare `--`, which the qml runner forwards
  // into Qt.application.arguments untouched.
  //   [0..n] runner arguments, then: outputPath epochMs latitude longitude magnitude
  function argumentAt(offsetFromEnd, fallback) {
    var args = Qt.application.arguments
    var index = args.length - offsetFromEnd
    return index >= 0 && args[index] !== undefined ? args[index] : fallback
  }

  property string outputPath: argumentAt(5, "preview-sky.png")
  property real previewEpochMs: Number(argumentAt(4, Date.now()))
  property real previewLatitude: Number(argumentAt(3, 40.1267))
  property real previewLongitude: Number(argumentAt(2, -82.9319))
  property int previewMagnitude: Number(argumentAt(1, 5))
  property bool previewLines: true
  property bool previewNames: true
  property bool previewBodies: true
  property bool previewMilkyWay: true

  // Stands in for the shell's bar object, which the chart reads for its theme
  // colour and font.
  QtObject {
    id: fakeBar
    readonly property color foreground: "#d7dceb"
    readonly property string fontFamily: "sans-serif"
  }

  Loader {
    id: chartLoader
    anchors.fill: parent
    anchors.margins: 20
    source: Qt.resolvedUrl("../../SkyChart.qml")

    onLoaded: {
      item.bar = fakeBar
      item.latitude = window.previewLatitude
      item.longitude = window.previewLongitude
      item.epochMs = window.previewEpochMs
      item.magnitudeLimit = window.previewMagnitude
      item.showLines = window.previewLines
      item.showNames = window.previewNames
      item.showBodies = window.previewBodies
      item.showMilkyWay = window.previewMilkyWay
      item.ready = true
      grabTimer.start()
    }
  }

  // Saved straight off the Canvas rather than through grabToImage: under the
  // offscreen platform the window never presents a frame, so a scene-graph grab
  // is scheduled and then never delivered. Canvas renders into its own image
  // buffer and can write that out with no compositor involved.
  Timer {
    id: grabTimer
    interval: 500
    repeat: false
    onTriggered: {
      var canvas = chartLoader.item ? chartLoader.item.canvasItem : null
      if (!canvas) { Qt.exit(3) }
      else if (!canvas.save(window.outputPath)) { Qt.exit(5) }
      else exitTimer.start()
    }
  }

  // Exiting from inside the save leaves Qt tearing down a canvas it is still
  // rendering, which segfaults. One more turn of the event loop is enough to
  // let it finish.
  Timer {
    id: exitTimer
    interval: 120
    repeat: false
    onTriggered: Qt.exit(0)
  }

  // Backstop, so a paint that never lands fails with a code render.sh can
  // report instead of hanging forever on a window nobody can see.
  Timer {
    interval: 20000
    repeat: false
    running: true
    onTriggered: Qt.exit(4)
  }
}
