import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The breakdown. One sentence up top says who is eating the machine, a
// sparkline shows where memory has been for the last half hour, and then
// two tanks, RAM and CPU, stand beside one row per app, heaviest first.
// Each tank segment is a row: hover either and the tanks dim to that one
// segment, with a line drawn to its row. Enter or a click on an app
// focuses its window; on a browser it drills into a view of that browser's
// pages, where Enter brings the tab to front. Every row that can be closed
// gets an × on hover and the x key, behind one confirmation that states
// what will be freed and what will be lost.
//
// Rows and segments are kept in ListModels keyed by row, so a fresh sample
// updates delegates in place and their moves animate instead of snapping.
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
  property string focusKey: ""
  readonly property bool focused: focusKey !== "" && rows.length > 0 && rows[0].type === "header"
  readonly property int maxApps: Math.max(3, Number(setting("maxApps", 10)) || 10)
  readonly property var rows: Model.buildRows(snapshot, focusKey, maxApps)
  readonly property var rowMap: Model.rowMap(rows)
  readonly property var memSegments: Model.tankSegments(snapshot, rows, "mem")
  readonly property var cpuSegments: Model.tankSegments(snapshot, rows, "cpu")
  readonly property var memSegMap: Model.segmentMap(memSegments)
  readonly property var cpuSegMap: Model.segmentMap(cpuSegments)
  readonly property var emptyRow: ({ type: "note", key: "", parentKey: "", name: "", comm: "", subtitle: "", mem: 0, cpu: 0, age: 0, count: 0, pids: [], root: 0, protectedRow: true, drillable: false, closable: false, browser: false, devtools: "", profile: "", targets: [], omarchy: false, icon: "", iconName: "", depth: 0 })

  ListModel { id: rowModel }
  ListModel { id: memModel }
  ListModel { id: cpuModel }

  onRowsChanged: syncKeys(rowModel, Model.keysOf(rows))
  onMemSegmentsChanged: syncKeys(memModel, Model.keysOf(memSegments))
  onCpuSegmentsChanged: syncKeys(cpuModel, Model.keysOf(cpuSegments))

  // Bring a ListModel of {key} into the given order with the fewest moves,
  // so existing delegates survive and animate to their new place.
  function syncKeys(model, keys) {
    for (var i = 0; i < keys.length; i++) {
      if (i < model.count && model.get(i).key === keys[i]) continue
      var found = -1
      for (var k = i + 1; k < model.count; k++) if (model.get(k).key === keys[i]) { found = k; break }
      if (found >= 0) model.move(found, i, 1)
      else model.insert(i, { key: keys[i] })
    }
    while (model.count > keys.length) model.remove(model.count - 1)
  }

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

  readonly property int rowHeight: Style.spacing.popupRowHeight + Style.space(2)
  readonly property int rowGap: Style.space(2)
  readonly property int iconSize: Style.space(16)

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
    if (root.focusKey !== "" && !Model.findApp(snap, root.focusKey)) root.focusKey = ""
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

  function clearCursor() {
    root.cursor = -1
    root.cursorKey = ""
  }

  // ---- Going places
  function drillInto(key) {
    root.focusKey = key
    clearCursor()
  }

  function drillOut() {
    var back = root.focusKey
    root.focusKey = ""
    Qt.callLater(function() { if (back !== "") setCursorKey(back) })
  }

  // Enter, or a click: a browser opens into its pages, an app comes to the
  // front, a page brings its tab forward. The panel steps aside once the
  // window is up.
  function activate(row) {
    if (!row || row.type === "note") return
    if (row.type === "header") { drillOut(); return }
    if (row.drillable) { drillInto(row.key); return }
    if (row.type === "site") {
      if (row.targets.length === 0) return
      goProc.command = ["python3", root.scriptPath, "activate-site", "--profile", row.profile, "--target", row.targets[0]]
      goProc.fallbackToTop = false
      goProc.running = true
      return
    }
    if (row.type === "bucket") return
    goProc.command = ["python3", root.scriptPath, "focus-app", "--pids", row.pids.join(",")]
    goProc.fallbackToTop = true
    goProc.running = true
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

  // ---- Icons. Apps resolve through their desktop entry; pages carry the
  //      favicon Chromium already cached, or the web app's own icon.
  property var iconCache: ({})

  function appIconSource(comm) {
    if (!comm) return ""
    if (root.iconCache[comm] !== undefined) return root.iconCache[comm]
    var src = ""
    try {
      var entry = DesktopEntries.heuristicLookup(comm)
      if (entry && entry.icon) src = Quickshell.iconPath(entry.icon, true)
      if (!src) src = Quickshell.iconPath(comm.toLowerCase(), true)
    } catch (e) { src = "" }
    var next = Object.assign({}, root.iconCache)
    next[comm] = src || ""
    root.iconCache = next
    return src || ""
  }

  function rowIconSource(row) {
    if (!row) return ""
    if (row.type === "site") {
      if (row.iconName) {
        var themed = Quickshell.iconPath(row.iconName, true)
        if (themed) return themed
      }
      return row.icon ? "file://" + row.icon : ""
    }
    return appIconSource(row.comm)
  }

  onOpenedChanged: {
    if (opened) {
      root.lastError = ""
      watchProc.running = true
    } else {
      watchProc.running = false
      clearCursor()
      root.focusKey = ""
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

  Process {
    id: goProc
    property bool fallbackToTop: false
    onExited: function(code) {
      if (code === 0) { root.close(); return }
      // No window to focus: btop is the next best place to look at it.
      if (code === 3 && goProc.fallbackToTop && root.bar) { root.bar.run("omarchy-launch-tui btop"); root.close(); return }
      root.lastError = "Could not bring that to front"
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
  //      row. Segments live in a keyed ListModel so a new sample slides
  //      them rather than redrawing. With a row under the cursor the rest
  //      of the tank dims and that segment alone takes the accent.
  component Tank: Item {
    id: tankItem
    property ListModel segmentModel: null
    property var segMap: ({})
    property string label: ""
    readonly property real innerHeight: Math.max(0, height - 2)

    function centerYFor(key) {
      var s = segMap[key]
      if (!s) return -1
      return 1 + innerHeight * (1 - s.start - s.frac / 2)
    }

    Rectangle {
      anchors.fill: parent
      radius: Math.min(Style.cornerRadius, width / 2)
      color: Qt.alpha(root.contentForeground, 0.05)
      border.width: 1
      border.color: Qt.alpha(root.contentForeground, 0.22)
      clip: true

      Repeater {
        model: tankItem.segmentModel

        Rectangle {
          id: segment
          required property string key
          readonly property var seg: tankItem.segMap[key] || null
          readonly property bool hot: root.cursorKey !== "" && key === root.cursorKey
          readonly property bool dimmedOut: root.cursorKey !== "" && !hot
          readonly property bool tail: key === "rest"
          readonly property real frac: seg ? seg.frac : 0
          readonly property real start: seg ? seg.start : 0
          readonly property real baseAlpha: tail ? 0.12 : (seg ? Model.segmentAlpha(seg.rank, seg.depth) : 0.2)
          x: 1
          width: parent.width - 2
          y: Math.round(1 + tankItem.innerHeight * (1 - start - frac))
          height: Math.max(1, Math.round(tankItem.innerHeight * frac) - 1)
          color: hot ? root.hotColor : Qt.alpha(root.contentForeground, dimmedOut ? baseAlpha * 0.28 : baseAlpha)

          Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
          Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 180 } }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            enabled: !segment.tail
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: root.setCursorKey(segment.key)
            onClicked: root.activate(root.rowMap[segment.key] || null)
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
          if (dx < 0 && root.focused) { root.drillOut(); return }
          var row = root.hoverRow
          if (dx > 0 && row && row.drillable) root.drillInto(row.key)
        }
        onActivateRequested: root.activate(root.hoverRow)
        onReturnRequested: root.activate(root.hoverRow)
        onDeleteRequested: root.requestClose(root.hoverRow)
        onCloseRequested: root.focused ? root.drillOut() : root.close()
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
                text: root.focused ? Model.focusTitle(root.rows) : Model.heroTitle(root.snapshot)
                color: root.tight && !root.focused ? root.urgentColor : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: (root.focused ? Model.focusMeta(root.rows, root.snapshot) : Model.heroMeta(root.snapshot)).toUpperCase()
                color: root.tight && !root.focused ? root.urgentColor : root.dim
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

          // ---------- Sparkline: RAM for the last half hour, CPU dotted behind ----------
          Item {
            width: parent.width
            implicitHeight: Style.space(26)
            visible: root.history.length >= 2 && !root.focused

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

                ctx.strokeStyle = Qt.alpha(ink, 0.12)
                ctx.lineWidth = 1
                ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke()

                ctx.strokeStyle = Qt.alpha(ink, 0.3)
                ctx.setLineDash([1, 3])
                ctx.beginPath()
                for (var c = 0; c < n; c++) { var yc = yAt(pts[c].cpu); if (c === 0) ctx.moveTo(xAt(c), yc); else ctx.lineTo(xAt(c), yc) }
                ctx.stroke()
                ctx.setLineDash([])

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
            id: body
            width: parent.width
            implicitHeight: Math.max(list.implicitHeight, Style.space(120)) + Style.space(18)

            Row {
              id: tanks
              anchors.left: parent.left
              anchors.top: parent.top
              height: list.implicitHeight
              spacing: Style.space(6)

              Tank { id: memTank; width: Style.space(18); height: parent.height; segmentModel: memModel; segMap: root.memSegMap; label: "RAM" }
              Tank { id: cpuTank; width: Style.space(18); height: parent.height; segmentModel: cpuModel; segMap: root.cpuSegMap; label: "CPU" }
            }

            // The line from the lit segment to its row: out of the CPU tank,
            // up or down the gutter, into the row. Every piece animates, so
            // moving the cursor draws it rather than replacing it.
            Item {
              id: connector
              readonly property bool active: root.cursorKey !== "" && root.cursor >= 0 && root.memSegMap[root.cursorKey] !== undefined
              readonly property real segY: active ? cpuTank.centerYFor(root.cursorKey) : 0
              readonly property real rowY: active ? root.cursor * (root.rowHeight + root.rowGap) + root.rowHeight / 2 : 0
              readonly property real xStart: tanks.x + tanks.width
              readonly property real xMid: xStart + Style.space(6)
              readonly property real xEnd: list.x - Style.space(1)
              readonly property real topY: Math.min(segY, rowY)
              readonly property real bottomY: Math.max(segY, rowY)
              visible: active
              opacity: active ? 1 : 0

              Behavior on opacity { NumberAnimation { duration: 160 } }

              Rectangle { x: connector.xStart; y: Math.round(connector.segY); width: connector.xMid - connector.xStart + 1; height: 1; color: root.hotColor
                Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } } }
              Rectangle { x: connector.xMid; y: Math.round(connector.topY); width: 1; height: Math.max(1, Math.round(connector.bottomY - connector.topY)); color: root.hotColor
                Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } } }
              Rectangle { x: connector.xMid; y: Math.round(connector.rowY); width: connector.xEnd - connector.xMid; height: 1; color: root.hotColor
                Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } } }
            }

            Column {
              id: list
              anchors.left: tanks.right
              anchors.leftMargin: Style.space(16)
              anchors.right: parent.right
              anchors.top: parent.top
              spacing: root.rowGap

              // Delegates follow the keyed model, so a row that changes rank
              // slides to its new place instead of being rebuilt there.
              move: Transition { NumberAnimation { properties: "y"; duration: 420; easing.type: Easing.OutCubic } }
              add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 } }

              Repeater {
                model: rowModel

                Item {
                  id: rowItem
                  required property string key
                  required property int index
                  readonly property var row: root.rowMap[key] || root.emptyRow
                  readonly property bool hot: root.cursor === index
                  readonly property bool isNote: row.type === "note"
                  readonly property bool isHeader: row.type === "header"
                  readonly property string status: root.rowStatus(row)
                  readonly property bool showClose: row.closable && (hot || closeMouse.containsMouse)
                  readonly property string iconSource: root.rowIconSource(row)

                  width: parent.width
                  height: root.rowHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: rowItem.hot ? Style.hoverFill : "transparent"
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: rowItem.isNote ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onPositionChanged: if (root.cursor !== rowItem.index) root.setCursor(rowItem.index)
                    onExited: if (root.cursor === rowItem.index && !closeMouse.containsMouse) root.clearCursor()
                    onClicked: root.activate(rowItem.row)
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.right: metrics.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    // Back arrow on the header, the app or site icon on the
                    // rest, a lettered dot when there is no icon to be had.
                    Item {
                      width: root.iconSize
                      height: root.iconSize
                      anchors.verticalCenter: parent.verticalCenter
                      visible: !rowItem.isNote

                      Text {
                        anchors.centerIn: parent
                        visible: rowItem.isHeader
                        textFormat: Text.PlainText
                        text: ""
                        color: root.dim
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                      }

                      Image {
                        id: rowIcon
                        anchors.fill: parent
                        visible: !rowItem.isHeader && status === Image.Ready
                        source: rowItem.isHeader ? "" : rowItem.iconSource
                        sourceSize.width: root.iconSize * 2
                        sourceSize.height: root.iconSize * 2
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        asynchronous: true
                      }

                      Rectangle {
                        anchors.fill: parent
                        visible: !rowItem.isHeader && rowIcon.status !== Image.Ready
                        radius: width / 2
                        color: Qt.alpha(root.contentForeground, 0.1)

                        Text {
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: rowItem.row.name ? rowItem.row.name.charAt(0).toUpperCase() : ""
                          color: root.dim
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: rowItem.row.name
                      color: rowItem.isNote ? root.dim : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: rowItem.isNote ? Style.font.caption : Style.font.body
                      font.bold: rowItem.isHeader
                      font.italic: rowItem.isNote
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, parent.width - root.iconSize - Style.space(8) - (subtitle.visible ? Style.space(50) : 0))
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
            text: root.focused ? "j k move · enter go to tab · h back · x close tab"
                               : "j k move · enter go to app · l into browser · x quit · b btop"
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
