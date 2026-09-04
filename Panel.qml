import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The breakdown. One sentence up top says who is eating the machine, a
// stacked bar shows the shares without numbers, and then one row per app,
// heaviest first. A browser row opens into sites. Every row that can be
// closed gets an × on hover and the x key, both behind one confirmation
// that states what will be freed and what will be lost.
//
// BarWidget.qml owns the bar glyph and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "apurva.omatop"
  ipcTarget: "apurva.omatop"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property string scriptPath: ""
  readonly property var barIdentity: hostWidget || root

  // ---- Data
  property var snapshot: null
  property var expanded: ({})
  readonly property int maxApps: Math.max(3, Number(setting("maxApps", 10)) || 10)
  readonly property var rows: Model.buildRows(snapshot, expanded, maxApps)
  readonly property var apps: snapshot && snapshot.apps ? snapshot.apps : []

  // ---- Cursor: shared by keyboard and pointer. -1 is "nothing yet".
  property int cursor: -1
  property string cursorKey: ""

  // ---- Confirmation and the escalation after a polite quit was ignored.
  property bool confirmOpen: false
  property var confirmRow: null
  property bool confirmForce: false
  property var pendingQuits: ({})   // app key -> ms when SIGTERM went out
  property string lastError: ""

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(contentForeground, 1.4)
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent

  function open() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.confirmOpen) cancelConfirm()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    if (!root.opened) return
    if (watchProc.running) {
      watchProc.running = false
    }
    watchProc.running = true
  }

  // ---- Snapshot intake
  function acceptSnapshot(line) {
    var snap
    try { snap = JSON.parse(line) } catch (e) { return }
    if (!snap || snap.light) return
    root.snapshot = snap
    reconcileCursor()
    reconcilePending(snap)
  }

  function reconcileCursor() {
    if (root.cursorKey === "") { root.cursor = -1; return }
    var idx = Model.indexOfKey(root.rows, root.cursorKey)
    if (idx >= 0) root.cursor = idx
    else { root.cursor = Model.clampIndex(root.cursor, root.rows.length); root.cursorKey = root.cursor >= 0 ? root.rows[root.cursor].key : "" }
  }

  function reconcilePending(snap) {
    var next = {}
    var alive = {}
    for (var i = 0; i < snap.apps.length; i++) alive[snap.apps[i].key] = true
    for (var key in root.pendingQuits) if (alive[key]) next[key] = root.pendingQuits[key]
    root.pendingQuits = next
  }

  function stillRunning(row) {
    if (!row || row.type !== "app") return false
    var at = root.pendingQuits[row.key]
    return at !== undefined && (Date.now() - at) > 5000
  }

  // ---- Cursor moves
  function moveCursor(delta) {
    if (root.rows.length === 0) return
    var next = root.cursor < 0 ? (delta > 0 ? 0 : root.rows.length - 1) : Model.clampIndex(root.cursor + delta, root.rows.length)
    setCursor(next)
  }

  function setCursor(index) {
    root.cursor = index
    root.cursorKey = index >= 0 && index < root.rows.length ? root.rows[index].key : ""
  }

  function currentRow() {
    return root.cursor >= 0 && root.cursor < root.rows.length ? root.rows[root.cursor] : null
  }

  function activate(row) {
    if (!row) return
    if (row.expandable) toggleExpanded(row.key)
  }

  function toggleExpanded(key) {
    var e = {}
    for (var k in root.expanded) e[k] = root.expanded[k]
    if (e[key]) delete e[key]
    else e[key] = true
    root.expanded = e
  }

  function setExpanded(key, value) {
    if ((root.expanded[key] === true) === value) return
    toggleExpanded(key)
  }

  // ---- Closing things
  function requestClose(row) {
    if (!row || !row.closable || actProc.running) return
    root.confirmRow = row
    root.confirmForce = stillRunning(row)
    root.confirmOpen = true
    confirmDialog.selectedIndex = 1
  }

  function cancelConfirm() {
    root.confirmOpen = false
    root.confirmRow = null
    root.confirmForce = false
  }

  function performClose() {
    var row = root.confirmRow
    var force = root.confirmForce
    cancelConfirm()
    if (!row) return
    root.lastError = ""
    if (row.type === "site") {
      actProc.command = ["python3", root.scriptPath, "close-site", "--profile", row.profile, "--targets", row.targets.join(",")]
    } else {
      var p = {}
      for (var k in root.pendingQuits) p[k] = root.pendingQuits[k]
      p[row.key] = Date.now()
      root.pendingQuits = p
      var args = ["python3", root.scriptPath, "kill", "--pids", (force ? row.pids : [row.root]).join(",")]
      if (force) args.push("--force")
      actProc.command = args
    }
    actProc.running = true
  }

  function rowStatus(row) {
    if (row.type === "app" && root.pendingQuits[row.key] !== undefined) {
      return stillRunning(row) ? "still running · x again to force" : "quitting…"
    }
    return ""
  }

  onOpenedChanged: {
    if (opened) {
      root.lastError = ""
      root.watchSerial++
      watchProc.running = true
    } else {
      watchProc.running = false
      root.cursor = -1
      root.cursorKey = ""
    }
  }

  property int watchSerial: 0

  // The sampler streams one JSON line every two seconds while the panel is
  // open and is stopped the moment it closes.
  Process {
    id: watchProc
    command: ["python3", root.scriptPath, "watch", "--interval", "2"]
    stdout: SplitParser {
      onRead: function(line) { root.acceptSnapshot(line) }
    }
    stderr: StdioCollector {
      waitForEnd: false
      onStreamFinished: {}
    }
  }

  Process {
    id: actProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") root.lastError = t.split("\n").pop()
      }
    }
    onExited: function(code) {
      if (code !== 0 && root.lastError === "") root.lastError = "That did not work (exit " + code + ")"
    }
  }

  Timer {
    // Re-evaluate "still running" labels without waiting for a sample.
    interval: 1000
    running: root.opened && Object.keys(root.pendingQuits).length > 0
    repeat: true
    onTriggered: root.pendingQuits = Object.assign({}, root.pendingQuits)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing

    Item {
      id: keyHost
      anchors.fill: parent

      // With the confirmation up the catcher stands down and the dialog
      // gets the keys: Enter confirms, Esc backs out, arrows pick a side.
      Keys.onPressed: function(event) {
        if (root.confirmOpen && confirmDialog.handleKey(event)) event.accepted = true
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: root.confirmOpen
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) { root.moveCursor(dy); return }
          var row = root.currentRow()
          if (!row || !row.expandable) return
          root.setExpanded(row.key, dx > 0)
        }
        onActivateRequested: root.activate(root.currentRow())
        onReturnRequested: root.activate(root.currentRow())
        onDeleteRequested: root.requestClose(root.currentRow())
        onCloseRequested: root.close()
        onTabRequested: function(direction) { root.switchPanel(direction) }
        onTextKey: function(text) {
          if (text === "r") root.refresh()
          else if (text === "b" && root.bar) root.bar.run("omarchy-launch-tui btop")
        }

        Column {
          id: column
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(12)

          // ---------- Hero: the sentence, the totals, the percentage ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󰍛"
              color: Model.isTight(root.snapshot) ? root.urgentColor : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroPercent.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: Model.heroTitle(root.snapshot)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: Model.heroMeta(root.snapshot).toUpperCase()
                color: Model.isTight(root.snapshot) ? root.urgentColor : root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Text {
              id: heroPercent
              textFormat: Text.PlainText
              text: root.snapshot ? Math.round(Model.usedFraction(root.snapshot) * 100) + "%" : "—"
              color: Model.isTight(root.snapshot) ? root.urgentColor : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              Behavior on color { ColorAnimation { duration: 200 } }
            }
          }

          // ---------- Shares: one stacked bar, biggest app at the left ----------
          // Position does the comparing; the numbers in the rows only confirm.
          Item {
            id: shareBar
            width: parent.width
            implicitHeight: Style.space(8)

            readonly property real total: root.snapshot && root.snapshot.mem ? root.snapshot.mem.total : 0
            readonly property int shown: Math.min(root.apps.length, 6)
            readonly property var alphas: Model.segmentAlphas(shown)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Qt.alpha(root.contentForeground, 0.08)
            }

            Row {
              anchors.fill: parent
              spacing: 1

              Repeater {
                model: shareBar.shown

                Rectangle {
                  required property int index
                  readonly property var app: root.apps[index]
                  readonly property bool hot: root.cursor >= 0 && root.cursor < root.rows.length && root.rows[root.cursor].key === app.key
                  height: parent.height
                  width: Math.max(0, Math.round(shareBar.width * Model.share(app.mem, shareBar.total)) - 1)
                  radius: index === 0 ? height / 2 : 0
                  color: hot ? (bar ? bar.urgent : Color.accent) : Qt.alpha(root.contentForeground, shareBar.alphas[index])

                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  Behavior on color { ColorAnimation { duration: 160 } }
                }
              }

              Rectangle {
                readonly property real rest: {
                  var s = 0
                  for (var i = shareBar.shown; i < root.apps.length; i++) s += root.apps[i].mem
                  return s
                }
                height: parent.height
                width: Math.max(0, Math.round(shareBar.width * Model.share(rest, shareBar.total)))
                color: Qt.alpha(root.contentForeground, 0.14)
                Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---------- Rows ----------
          Column {
            id: list
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.rows

              Item {
                id: rowItem
                required property var modelData
                required property int index
                readonly property var row: modelData
                readonly property bool hot: root.cursor === index
                readonly property bool isNote: row.type === "note"
                readonly property bool isMore: false
                readonly property string status: root.rowStatus(row)
                readonly property real memShare: root.snapshot && root.snapshot.mem ? Model.share(row.mem, root.snapshot.mem.used) : 0
                readonly property bool showClose: row.closable && (hot || closeMouse.containsMouse)

                width: parent.width
                height: isNote ? Style.space(24) : Style.spacing.popupRowHeight + Style.space(4)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: rowItem.hot ? Style.hoverFill : "transparent"
                }

                // The row's own share of used memory, as a faint fill from the
                // left. Sorted rows make it a bar chart without axes.
                Rectangle {
                  visible: !rowItem.isNote && !rowItem.isMore
                  anchors.left: parent.left
                  anchors.leftMargin: rowItem.row.depth * Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  height: parent.height - Style.space(6)
                  width: Math.max(0, Math.round((parent.width - anchors.leftMargin) * rowItem.memShare))
                  radius: Style.cornerRadius
                  color: Qt.alpha(root.contentForeground, rowItem.row.depth > 0 ? 0.04 : 0.07)
                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: rowItem.isNote ? Qt.ArrowCursor : Qt.PointingHandCursor
                  // Rows are rebuilt on every sample, and a fresh MouseArea
                  // under a resting pointer fires entered(): only a pointer
                  // that actually moves may take the cursor from the keys.
                  onPositionChanged: if (root.cursor !== rowItem.index) root.setCursor(rowItem.index)
                  onClicked: root.activate(rowItem.row)
                }

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8) + rowItem.row.depth * Style.space(16)
                  anchors.right: metrics.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    visible: rowItem.row.expandable
                    textFormat: Text.PlainText
                    text: rowItem.row.expanded ? "" : ""
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: rowItem.row.name
                    color: rowItem.isNote || rowItem.isMore ? root.dim : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: rowItem.isNote ? Style.font.caption : Style.font.body
                    font.italic: rowItem.isNote
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width - (subtitle.visible ? Style.space(60) : 0))
                  }

                  Text {
                    id: subtitle
                    visible: text !== ""
                    textFormat: Text.PlainText
                    text: rowItem.status !== "" ? rowItem.status : rowItem.row.subtitle
                    color: rowItem.status !== "" && root.stillRunning(rowItem.row) ? root.urgentColor : root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    width: Math.max(0, parent.width - x)
                  }
                }

                Row {
                  id: metrics
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  Text {
                    visible: !rowItem.isNote && !rowItem.isMore
                    textFormat: Text.PlainText
                    text: Model.fmtCpu(rowItem.row.cpu)
                    color: rowItem.row.cpu >= 50 ? root.contentForeground : root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    width: Style.space(34)
                  }

                  Text {
                    visible: !rowItem.isNote
                    textFormat: Text.PlainText
                    text: Model.fmtMem(rowItem.row.mem)
                    color: rowItem.isMore ? root.dim : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    width: Style.space(58)
                  }

                  // Close lives at the end of the row and only shows itself
                  // on the row under the cursor: the panel reads as a
                  // report until you reach for it.
                  Item {
                    width: Style.space(22)
                    height: Style.space(22)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: "×"
                      visible: rowItem.showClose
                      color: closeMouse.containsMouse ? root.urgentColor : root.dim
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.title
                    }

                    MouseArea {
                      id: closeMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      enabled: rowItem.row.closable
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: if (root.cursor !== rowItem.index) root.setCursor(rowItem.index)
                      onClicked: root.requestClose(rowItem.row)
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.lastError !== ""
            textFormat: Text.PlainText
            text: root.lastError
            color: root.urgentColor
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            elide: Text.ElideRight
          }

          // ---------- Keys ----------
          Text {
            textFormat: Text.PlainText
            text: "j k move · enter open · x close · b btop"
            color: Qt.alpha(root.dim, 0.7)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            width: parent.width
            elide: Text.ElideRight
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        anchors.margins: -panel.padding
        opened: root.confirmOpen
        z: 10
        message: Model.confirmMessage(root.confirmRow, root.confirmForce)
        confirmText: Model.confirmVerb(root.confirmRow, root.confirmForce)
        background: Color.popups.background
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily
        onCanceled: root.cancelConfirm()
        onConfirmed: root.performClose()
      }
    }
  }
}
