pragma Singleton
import QtQuick

// Stand-in for omarchy-shell's Style singleton (qs.Commons.Style), so the chart
// can be rendered outside the shell. Only the members SkyChart.qml actually
// touches are defined, with the shell's own default values.
QtObject {
  readonly property QtObject font: QtObject {
    readonly property int body: 12
    readonly property int bodySmall: 11
    readonly property int title: 14
  }
  function space(value) { return value }
  function spaceReal(value) { return value }
}
