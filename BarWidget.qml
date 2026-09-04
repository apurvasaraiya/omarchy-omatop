import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar end of Omatop: a memory glyph with a mark under it that fills as
// RAM fills. Left click opens the breakdown, middle click reads the whole
// picture aloud as a notification, right click opens btop for the people who
// want every process after all.
BarWidget {
  id: root
  moduleName: "apurva.omatop"

  // Whatever the panel last saw: it runs the real sampler; the bar only
  // takes the cheap memory reading between openings.
  property var snapshot: null
  readonly property real usedFraction: Model.usedFraction(snapshot)
  readonly property bool tight: Model.isTight(snapshot)

  readonly property string scriptPath: String(Qt.resolvedUrl("omatop")).replace(/^file:\/\//, "")

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property real openPanelIndicatorWidth: Math.round(Style.bar.iconSlot * 0.55)

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("scriptPath" in target) target.scriptPath = root.scriptPath
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  Connections {
    target: panelLoader.item
    ignoreUnknownSignals: true
    function onSnapshotChanged() {
      if (panelLoader.item && panelLoader.item.snapshot) root.snapshot = panelLoader.item.snapshot
    }
  }

  // Between openings only /proc/meminfo is read: one short process every
  // twenty seconds, nothing per-process, nothing near the browser.
  Process {
    id: lightProc
    command: ["python3", root.scriptPath, "watch", "--light", "--once"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var line = String(text || "").trim().split("\n").pop()
        if (!line) return
        try { root.snapshot = JSON.parse(line) } catch (e) {}
      }
    }
  }

  Timer {
    interval: 20000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!lightProc.running) lightProc.running = true
  }

  IpcHandler {
    target: "apurva.omatop"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍛"
    active: root.tight
    tooltipText: Model.barTooltip(root.snapshot)

    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.bar) root.bar.run("omarchy-launch-tui btop") }
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-notification-send \"" + Model.barTooltip(root.snapshot).replace(/"/g, "") + "\"") }
      else root.togglePanel()
    }

    // The mark under the glyph is the memory gauge: its fill is the share of
    // RAM in use. Hidden while the panel is open, where the bar's own
    // open-panel rule takes the same spot.
    Rectangle {
      visible: !root.vertical && !root.opened && root.snapshot !== null
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 2
      width: root.openPanelIndicatorWidth
      height: 1
      color: Qt.alpha(button.foreground, 0.25)

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(1, Math.round(parent.width * root.usedFraction))
        height: root.tight ? 2 : 1
        color: root.tight ? button.activeColor : button.foreground

        Behavior on width { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
      }
    }
  }
}
