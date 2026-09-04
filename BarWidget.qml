import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar end of Omatop. The icon is a small tank: its fill is the share of
// RAM in use, and it takes the bar's active colour when the CPU is
// saturated or memory is nearly gone. There is no glyph and no separate
// mark; the gauge is the icon. Left click opens the breakdown, middle click
// posts the numbers as a notification, right click opens btop.
BarWidget {
  id: root
  moduleName: "apurva.omatop"

  // Whatever the panel last saw: it runs the real sampler; the bar only
  // takes the cheap memory reading between openings.
  property var snapshot: null
  readonly property real usedFraction: Model.usedFraction(snapshot)
  readonly property real cpuFraction: Math.min(1, Model.loadFraction(snapshot))
  readonly property string state: Model.barState(snapshot)
  readonly property bool hot: state === "hot"
  readonly property bool cpuHot: state === "cpu"

  // One point every twenty seconds, half an hour deep, for the panel's
  // sparkline. Kept here so it survives the panel closing.
  property var history: []

  // Bumped on every press; the tank sloshes in answer.
  property int pressSerial: 0

  onSnapshotChanged: history = Model.pushHistory(history, snapshot, Date.now())

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

  // Between openings only /proc/meminfo and the load average are read: one
  // short process every twenty seconds, nothing per-process, nothing near
  // the browser.
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
    active: root.hot || root.cpuHot
    tooltipText: Model.barTooltip(root.snapshot)

    // The tank. Outline at the glyph's weight, fill rising from the bottom
    // with the share of RAM in use. A calm machine draws it quietly; a busy
    // one at full strength; a saturated CPU or tight memory in the active
    // colour, breathing slowly. A press squashes it and the liquid settles
    // back: the one flourish, and it answers the hand.
    iconComponent: Component {
      Item {
        id: tank
        readonly property color ink: button.active && button.useActiveColor ? button.activeColor : button.foreground
        readonly property real tankWidth: Math.round(width * 0.5)
        readonly property real tankHeight: Math.round(height * 0.92)
        opacity: root.state === "calm" ? 0.7 : 1
        transformOrigin: Item.Bottom

        Behavior on opacity { NumberAnimation { duration: 400 } }

        Connections {
          target: root
          function onPressSerialChanged() { slosh.restart() }
        }

        SequentialAnimation {
          id: slosh
          NumberAnimation { target: tank; property: "scale"; to: 0.82; duration: 90; easing.type: Easing.OutQuad }
          NumberAnimation { target: tank; property: "scale"; to: 1.1; duration: 140; easing.type: Easing.OutQuad }
          NumberAnimation { target: tank; property: "scale"; to: 1.0; duration: 220; easing.type: Easing.OutBack }
        }

        Rectangle {
          id: shell
          anchors.centerIn: parent
          width: tank.tankWidth
          height: tank.tankHeight
          radius: width / 2
          color: "transparent"
          border.width: 1
          border.color: tank.ink
          clip: true

          Behavior on border.color { ColorAnimation { duration: 300 } }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 1
            height: Math.max(0, Math.round((parent.height - 2) * root.usedFraction))
            radius: (parent.width - 2) / 2
            color: tank.ink

            Behavior on height { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 300 } }

            SequentialAnimation on opacity {
              running: root.hot || root.cpuHot
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.4; duration: 1400; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.4; to: 1.0; duration: 1400; easing.type: Easing.InOutSine }
            }
          }
        }
      }
    }

    onPressed: function(b) {
      root.pressSerial++
      if (b === Qt.RightButton) { if (root.bar) root.bar.run("omarchy-launch-tui btop") }
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-notification-send \"" + Model.barTooltip(root.snapshot).replace(/"/g, "") + "\"") }
      else root.togglePanel()
    }
  }
}
