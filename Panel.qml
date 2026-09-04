import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The breakdown. One sentence up top says who is eating the machine, a
// sparkline shows where memory has been for the last half hour, and then
// two tanks, RAM and CPU, stand beside one row per app, heaviest first.
// Each tank segment is a row: hover either and both light up, and the
// hero's second line reads that row out. A browser row opens into pages
// and its segment splits with it. Every row that can be closed gets an ×
// on hover and the x key, behind one confirmation that states what will
// be freed and what will be lost.
//
// BarWidget.qml owns the bar tank and hands this panel the button to
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
  readonly property var history: hostWidget && hostWidget.history ? hostWidget.history : []

  // ---- Data
  property var snapshot: null
  property var expanded: ({})
  readonly property int maxApps: Math.max(3, Number(setting("maxApps", 10)) || 10)
  readonly property var rows: Model.buildRows(snapshot, expanded, maxApps)
  readonly property var memSegments: Model.stackSegments(Model.tankSegments(snapshot, rows, "mem"))
  readonly property var cpuSegments: Model.stackSegments(Model.tankSegments(snapshot, rows, "cpu"))

  // ---- Cursor: shared by keyboard, rows and tank segments. -1 is "nothing yet".
  property int cursor: -1
  property string cursorKey: ""
  readonly property var hoverRow: cursor >= 0 && cursor < rows.length ? rows[cursor] : null

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
  readonly property color hotColor: Color.accent
  readonly property bool tight: Model.isTight(snapshot)

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
    if (watchProc.running) watchProc.running = false
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
    else {
      root.cursor = Model.clampIndex(root.cursor, root.rows.length)
      root.cursorKey = root.cursor >= 0 ? root.rows[root.cursor].key : ""
    }
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

  function setCursorKey(key) {
    var idx = Model.indexOfKey(root.rows, key)
    if (idx >= 0 && idx !== root.cursor) setCursor(idx)
  }

  function currentRow() {
    return root.hoverRow
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
    Qt.callLater(reconcileCursor)
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
      watchProc.running = true
    } else {
      watchProc.running = false
      root.cursor = -1
      root.cursorKey = ""
    }
  }

  // The sampler streams one JSON line every two seconds while the panel is
  // open and is stopped the moment it closes.
  Process {
    id: watchProc
    command: ["python3", root.scriptPath, "watch", "--interval", "2"]
    stdout: SplitParser {
      onRead: function(line) { root.acceptSnapshot(line) }
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

  // ---- A tank: an outlined column filled bottom-up with one segment per
  //      row. Hovering a segment moves the cursor to its row; the row under
  //      the cursor paints its segment in the accent.
  component Tank: Item {
    id: tankItem
    property var segments: []
    property string label: ""
    readonly property real innerHeight: Math.max(0, height - 2)

    Rectangle {
      anchors.fill: parent
      radius: Math.min(Style.cornerRadius, width / 2)
      color: Qt.alpha(root.contentForeground, 0.05)
      border.width: 1
      border.color: Qt.alpha(root.contentForeground, 0.22)
      clip: true

      Repeater {
        model: tankItem.segments

        Rectangle {
          required property var modelData
          readonly property bool hot: Model.segmentHot(modelData, root.cursorKey)
          readonly property bool child: modelData.depth > 0
          readonly property bool tail: modelData.key === "rest"
          x: child ? 4 : 1
          width: parent.width - x * 2
          y: Math.round(1 + tankItem.innerHeight * (1 - modelData.start - modelData.frac))
          height: Math.max(1, Math.round(tankItem.innerHeight * modelData.frac) - 1)
          color: hot ? root.hotColor
            : tail ? Qt.alpha(root.contentForeground, 0.12)
            : Qt.alpha(root.contentForeground, Model.segmentAlpha(modelData.rank, modelData.depth))

          Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
          Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 140 } }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            enabled: !parent.tail
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: root.setCursorKey(parent.modelData.key.endsWith("/rest") ? parent.modelData.parentKey : parent.modelData.key)
            onClicked: root.activate(root.hoverRow)
          }
        }
      }
    }

    Text {
      anchors.top: parent.bottom
      anchors.topMargin: Style.space(4)
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: tankItem.label
      color: root.dim
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
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
          var row = root.hoverRow
          if (!row) return
          var target = row.expandable ? row : null
          if (!target && row.parentKey !== "" && dx < 0) {
            // h on a child folds the parent and lands on it.
            var parentIdx = Model.indexOfKey(root.rows, row.parentKey)
            if (parentIdx >= 0) { root.setCursor(parentIdx); root.setExpanded(row.parentKey, false) }
            return
          }
          if (target) root.setExpanded(target.key, dx > 0)
        }
        onActivateRequested: root.activate(root.hoverRow)
        onReturnRequested: root.activate(root.hoverRow)
        onDeleteRequested: root.requestClose(root.hoverRow)
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

          // ---------- Hero: the sentence, the line under it, the percentage ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroLabels.implicitHeight, heroPercent.implicitHeight)

            Column {
              id: heroLabels
              anchors.left: parent.left
              anchors.right: heroPercent.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: Model.heroTitle(root.snapshot)
                color: root.tight ? root.urgentColor : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              // The totals, or the row under the cursor in the same units.
              Text {
                textFormat: Text.PlainText
                text: (root.hoverRow ? (root.hoverRow.name + " · " + Model.hoverMeta(root.hoverRow, root.snapshot)) : Model.heroMeta(root.snapshot)).toUpperCase()
                color: root.hoverRow ? root.hotColor : (root.tight ? root.urgentColor : root.dim)
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
              color: root.tight ? root.urgentColor : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              Behavior on color { ColorAnimation { duration: 200 } }
            }
          }

          // ---------- Sparkline: RAM for the last half hour, CPU faint behind it ----------
          Item {
            width: parent.width
            implicitHeight: Style.space(26)
            visible: root.history.length >= 2

            Canvas {
              id: spark
              anchors.left: parent.left
              anchors.right: sparkCaption.left
              anchors.rightMargin: Style.space(10)
              anchors.top: parent.top
              anchors.bottom: parent.bottom

              readonly property var points: root.history
              readonly property color ink: root.contentForeground
              onPointsChanged: requestPaint()
              onInkChanged: requestPaint()
              onWidthChanged: requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var pts = points
                var n = pts.length
                if (n < 2 || width <= 0) return
                var w = width, h = height
                var stepX = w / (Model.HISTORY_MAX - 1)
                var x0 = w - stepX * (n - 1)
                function xAt(i) { return x0 + stepX * i }
                function yAt(v) { return 1 + (h - 2) * (1 - v) }

                // Faint baseline, so a flat line still reads as a chart.
                ctx.strokeStyle = Qt.alpha(ink, 0.12)
                ctx.lineWidth = 1
                ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke()

                // CPU: dotted, behind.
                ctx.strokeStyle = Qt.alpha(ink, 0.3)
                ctx.setLineDash([1, 3])
                ctx.beginPath()
                for (var c = 0; c < n; c++) { var yc = yAt(pts[c].cpu); if (c === 0) ctx.moveTo(xAt(c), yc); else ctx.lineTo(xAt(c), yc) }
                ctx.stroke()
                ctx.setLineDash([])

                // RAM: filled area under a solid line.
                ctx.beginPath()
                ctx.moveTo(xAt(0), h)
                for (var i = 0; i < n; i++) ctx.lineTo(xAt(i), yAt(pts[i].mem))
                ctx.lineTo(xAt(n - 1), h)
                ctx.closePath()
                ctx.fillStyle = Qt.alpha(ink, 0.10)
                ctx.fill()
                ctx.beginPath()
                for (var j = 0; j < n; j++) { var y = yAt(pts[j].mem); if (j === 0) ctx.moveTo(xAt(j), y); else ctx.lineTo(xAt(j), y) }
                ctx.strokeStyle = Qt.alpha(ink, 0.8)
                ctx.lineWidth = 1.5
                ctx.stroke()

                // Now.
                ctx.fillStyle = root.tight ? root.urgentColor : ink
                ctx.beginPath(); ctx.arc(xAt(n - 1), yAt(pts[n - 1].mem), 2.2, 0, Math.PI * 2); ctx.fill()
              }
            }

            Column {
              id: sparkCaption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: Model.historyTrend(root.history)
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: Model.historySpan(root.history)
                color: Qt.alpha(root.dim, 0.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---------- Tanks beside the rows ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(list.implicitHeight, Style.space(120)) + Style.space(18)

            Row {
              id: tanks
              anchors.left: parent.left
              anchors.top: parent.top
              height: list.implicitHeight
              spacing: Style.space(6)

              Tank { width: Style.space(18); height: parent.height; segments: root.memSegments; label: "RAM" }
              Tank { width: Style.space(18); height: parent.height; segments: root.cpuSegments; label: "CPU" }
            }

            Column {
              id: list
              anchors.left: tanks.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.top: parent.top
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
                  readonly property string status: root.rowStatus(row)
                  readonly property bool showClose: row.closable && (hot || closeMouse.containsMouse)

                  width: parent.width
                  height: isNote ? Style.space(22) : Style.spacing.popupRowHeight + Style.space(2)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: rowItem.hot ? Style.hoverFill : "transparent"
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
                    anchors.leftMargin: Style.space(6) + rowItem.row.depth * Style.space(14)
                    anchors.right: metrics.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(7)

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
                      color: rowItem.isNote ? root.dim : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: rowItem.isNote ? Style.font.caption : Style.font.body
                      font.italic: rowItem.isNote
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, parent.width - (subtitle.visible ? Style.space(50) : 0))
                    }

                    Text {
                      id: subtitle
                      visible: text !== ""
                      textFormat: Text.PlainText
                      text: rowItem.status !== "" ? rowItem.status : rowItem.row.subtitle
                      color: rowItem.status !== "" && root.stillRunning(rowItem.row) ? root.urgentColor
                        : rowItem.row.omarchy ? Qt.alpha(root.hotColor, 0.85) : root.dim
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
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      visible: !rowItem.isNote
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
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                      horizontalAlignment: Text.AlignRight
                      width: Style.space(56)
                    }

                    // Close lives at the end of the row and only shows itself
                    // on the row under the cursor: the panel reads as a
                    // report until you reach for it.
                    Item {
                      width: Style.space(20)
                      height: Style.space(20)
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
            text: "j k move · l h open close · x close · b btop"
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
