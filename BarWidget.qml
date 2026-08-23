import QtQuick
import qs.Commons
import qs.Ui

// The bar slot. Everything it shows is derived in Panel.qml, which owns the
// location and the solar arithmetic; this file is only the bar-side presence
// and the click target that opens the panel.
BarWidget {
  id: root
  moduleName: "kairos.night-sky"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  implicitWidth: content.implicitWidth
  implicitHeight: content.implicitHeight
  visible: true

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // The panel is loaded at startup rather than on demand, because the bar label
  // itself comes from it -- the widget would read "SKY --" until first opened
  // otherwise. This costs little: the panel holds the location and the solar
  // maths, while the far heavier star catalogue sits behind a second Loader
  // inside the panel that stays inactive until someone actually opens it.
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Row {
    id: content
    spacing: 0

    WidgetButton {
      id: button
      bar: root.bar
      text: panelLoader.item ? panelLoader.item.label : "SKY --"
      tooltipText: panelLoader.item ? panelLoader.item.tooltip : "Night Sky"
      hasVisualContent: true
      labelVisible: true
      // Matches the flight-tracker's margin for the same reason: the shell
      // sizes a bar slot from this label's measured implicitWidth, and native
      // text rendering can paint a glyph slightly wider than it measured. The
      // buffer keeps that drift from reaching the neighbouring slot.
      horizontalMargin: 14

      onPressed: root.togglePanel()
    }
  }
}
