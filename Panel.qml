import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The breakdown. One sentence up top says who is eating the machine, a
// sparkline shows where memory has been for the last half hour, and then
// three tanks, RAM, CPU and GPU, stand beside one row per app. Each tank
// segment is a row: hover either and the tanks dim to that one segment,
// with a band drawn tank to tank and into the row. Column titles sort;
// "/" searches. Enter or a click on an app focuses its window; on a
// browser it drills into a view of that browser's pages, where Enter brings
// the tab to front. Every row that can be closed gets an × on hover and
// the x key, behind one confirmation that states what will be freed and
// what will be lost.
//
// Tanks are painted on a canvas that morphs from the last layout to the
// new one, so a sample that changes sizes or order flows rather than
// snaps. Rows live in a keyed ListModel updated in place for the same
// reason.
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
  property string query: ""
  property bool searching: false
  readonly property string sortKey: String(setting("sort", "mem"))
  readonly property bool focused: focusKey !== "" && rows.length > 0 && rows[0].type === "header"
  readonly property int maxApps: Math.max(3, Number(setting("maxApps", 10)) || 10)
  readonly property var rows: limitRows(Model.arrangeRows(Model.buildRows(snapshot, focusKey, 1000), sortKey, query))
  readonly property var rowMap: Model.rowMap(rows)
  readonly property var memSegments: Model.tankSegments(snapshot, rows, "mem")
  readonly property var cpuSegments: Model.tankSegments(snapshot, rows, "cpu")
  readonly property var gpuSegments: Model.tankSegments(snapshot, rows, "gpu")
  readonly property var emptyRow: ({ type: "note", key: "", parentKey: "", name: "", comm: "", subtitle: "", mem: 0, cpu: 0, gpu: 0, net: 0, age: 0, count: 0, pids: [], root: 0, protectedRow: true, drillable: false, closable: false, browser: false, devtools: "", profile: "", targets: [], omarchy: false, icon: "", iconName: "", depth: 0 })

  // The ten heaviest by the chosen column; the header and the browser's
  // own row are not counted.
  function limitRows(all) {
    var out = []
    var body = 0
    for (var i = 0; i < all.length; i++) {
      var r = all[i]
      if (r.type === "app" || r.type === "site") {
        if (body >= root.maxApps) continue
        body++
      }
      out.push(r)
    }
    return out
  }

  ListModel { id: rowModel }
  onRowsChanged: syncKeys(rowModel, Model.keysOf(rows))

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
  readonly property int colCpu: Style.space(36)
  readonly property int colMem: Style.space(56)
  readonly property int colGpu: Style.space(36)
  readonly property int colNet: Style.space(34)
  readonly property int colClose: Style.space(20)
  readonly property int colGap: Style.space(8)

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
    if (root.pendingBrowser) {
      root.pendingBrowser = false
      for (var b = 0; b < snap.apps.length; b++) if (snap.apps[b].browser) { drillInto(snap.apps[b].key); break }
    }
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

  // ---- Sorting. The choice is written back to shell.json, so it is the
  //      order from then on rather than one that resets with the panel.
  function setSort(key) {
    if (Model.SORTS.indexOf(key) < 0 || key === root.sortKey) return
    root.settings = Object.assign({}, root.settings, { sort: key })
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, root.settings)
    Qt.callLater(reconcileCursor)
  }

  // ---- Going places
  function drillInto(key) {
    root.focusKey = key
    root.query = ""
    clearCursor()
  }

  function drillOut() {
    var back = root.focusKey
    root.focusKey = ""
    root.query = ""
    Qt.callLater(function() { if (back !== "") setCursorKey(back) })
  }

  // Straight into the browser's pages, for a keybind or the IPC.
  function openBrowser() {
    root.open()
    var apps = root.snapshot && root.snapshot.apps ? root.snapshot.apps : []
    for (var i = 0; i < apps.length; i++) if (apps[i].browser) { drillInto(apps[i].key); return }
    root.pendingBrowser = true
  }
  property bool pendingBrowser: false

  // Enter, or a click: a browser opens into its pages, an app comes to the
  // front, a page brings its tab forward. The panel closes first: while it
  // holds the keyboard the compositor will not hand focus to anyone else.
  function activate(row) {
    if (!row || row.type === "note" || row.type === "bucket") return
    if (row.type === "header") { drillOut(); return }
    if (row.drillable) { drillInto(row.key); return }
    var cmd
    var fallback = false
    if (row.type === "site") {
      if (row.targets.length === 0) return
      cmd = ["python3", root.scriptPath, "activate-site", "--profile", row.profile, "--target", row.targets[0]]
    } else {
      cmd = ["python3", root.scriptPath, "focus-app", "--pids", row.pids.join(",")]
      fallback = true
    }
    goTimer.cmd = cmd
    goTimer.fallback = fallback
    root.close()
    goTimer.restart()
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

  // ---- Search: "/" opens it, letters go to it, Backspace edits, Enter
  //      keeps the filter and returns the keys, Esc drops it.
  function handleSearchKey(event) {
    if (event.key === Qt.Key_Escape) { root.query = ""; root.searching = false; return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.searching = false; return true }
    if (event.key === Qt.Key_Backspace) { root.query = root.query.slice(0, -1); return true }
    if (event.text && event.text.length === 1 && event.text >= " ") { root.query += event.text; return true }
    return false
  }

  // ---- Icons. Apps resolve through their desktop entry; pages carry the
  //      favicon Chromium already cached, or the web app's own icon.
  // Mutated in place, never reassigned: a lookup from inside a binding
  // must not notify that same binding.
  readonly property var iconCache: ({})

  function appIconSource(comm) {
    if (!comm) return ""
    var cached = root.iconCache[comm]
    if (cached !== undefined) return cached
    var src = ""
    try {
      var entry = DesktopEntries.heuristicLookup(comm)
      if (entry && entry.icon) src = Quickshell.iconPath(entry.icon, true)
      if (!src) src = Quickshell.iconPath(comm.toLowerCase(), true)
    } catch (e) { src = "" }
    root.iconCache[comm] = src || ""
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
      root.query = ""
      root.searching = false
      root.pendingBrowser = false
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
    id: goTimer
    interval: 160
    property var cmd: []
    property bool fallback: false
    onTriggered: {
      goProc.command = goTimer.cmd
      goProc.fallbackToTop = goTimer.fallback
      goProc.running = true
    }
  }

  Process {
    id: goProc
    property bool fallbackToTop: false
    onExited: function(code) {
      if (code === 0) return
      // No window to focus: btop is the next best place to look at it.
      if (code === 3 && goProc.fallbackToTop && root.bar) { root.bar.run("omarchy-launch-tui btop"); return }
      if (root.bar) root.bar.run("omarchy-notification-send \"Omatop could not bring that to front\"")
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
  //      row, painted on a canvas. A new layout does not replace the old
  //      one; the canvas morphs between them over 800 ms, keys sliding,
  //      newcomers growing from their place, leavers shrinking where they
  //      stood. With a row under the cursor the rest of the tank dims and
  //      that segment alone takes the accent.
  component Tank: Item {
    id: tankItem
    property var target: []
    property string label: ""
    property var shown: []
    property var shownMap: ({})
    property var fromMap: ({})
    property real progress: 1
    readonly property real innerHeight: Math.max(0, height - 2)

    onTargetChanged: {
      tankItem.fromMap = tankItem.shownMap
      tankItem.progress = 0
      morph.restart()
    }

    NumberAnimation {
      id: morph
      target: tankItem
      property: "progress"
      from: 0
      to: 1
      duration: 800
      easing.type: Easing.InOutCubic
    }

    onProgressChanged: repaint()
    onInnerHeightChanged: repaint()

    function repaint() {
      var next = Model.morphSegments(tankItem.fromMap, tankItem.target, tankItem.progress)
      var m = {}
      for (var i = 0; i < next.length; i++) m[next[i].key] = next[i]
      tankItem.shown = next
      tankItem.shownMap = m
      canvas.requestPaint()
    }

    // Top and bottom of a segment in this item's coordinates, or null.
    function segmentSpan(key) {
      var s = tankItem.shownMap[key]
      if (!s) return null
      var top = 1 + tankItem.innerHeight * (1 - s.start - s.frac)
      return { top: top, bottom: top + tankItem.innerHeight * s.frac }
    }

    function keyAt(y) {
      for (var i = 0; i < tankItem.shown.length; i++) {
        var s = tankItem.shown[i]
        if (s.key === "rest") continue
        var top = 1 + tankItem.innerHeight * (1 - s.start - s.frac)
        if (y >= top && y <= top + tankItem.innerHeight * s.frac) return s.key
      }
      return ""
    }

    Connections {
      target: root
      function onCursorKeyChanged() { canvas.requestPaint() }
    }

    Canvas {
      id: canvas
      anchors.fill: parent

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var w = width, h = height
        var r = Math.min(Style.cornerRadius, w / 2)
        var fg = root.contentForeground

        function rounded(x, y, rw, rh, rr) {
          ctx.beginPath()
          ctx.moveTo(x + rr, y)
          ctx.lineTo(x + rw - rr, y)
          ctx.arcTo(x + rw, y, x + rw, y + rr, rr)
          ctx.lineTo(x + rw, y + rh - rr)
          ctx.arcTo(x + rw, y + rh, x + rw - rr, y + rh, rr)
          ctx.lineTo(x + rr, y + rh)
          ctx.arcTo(x, y + rh, x, y + rh - rr, rr)
          ctx.lineTo(x, y + rr)
          ctx.arcTo(x, y, x + rr, y, rr)
          ctx.closePath()
        }

        rounded(0.5, 0.5, w - 1, h - 1, r)
        ctx.fillStyle = Qt.alpha(fg, 0.05)
        ctx.fill()
        ctx.save()
        ctx.clip()

        var hovering = root.cursorKey !== ""
        var inner = tankItem.innerHeight
        for (var i = 0; i < tankItem.shown.length; i++) {
          var s = tankItem.shown[i]
          var top = 1 + inner * (1 - s.start - s.frac)
          var sh = inner * s.frac
          if (sh < 0.5) continue
          var hot = hovering && s.key === root.cursorKey
          var alpha = s.key === "rest" ? 0.12 : Model.segmentAlpha(s.rank, s.depth)
          if (hovering && !hot) alpha *= 0.28
          ctx.fillStyle = hot ? root.hotColor : Qt.alpha(fg, alpha)
          ctx.fillRect(1, top, w - 2, Math.max(0.5, sh - 1))
        }
        ctx.restore()

        rounded(0.5, 0.5, w - 1, h - 1, r)
        ctx.strokeStyle = Qt.alpha(fg, 0.22)
        ctx.lineWidth = 1
        ctx.stroke()
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: function(mouse) {
        var key = tankItem.keyAt(mouse.y)
        if (key !== "") root.setCursorKey(key)
      }
      onClicked: function(mouse) {
        var key = tankItem.keyAt(mouse.y)
        if (key !== "") root.activate(root.rowMap[key] || null)
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
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing

    Item {
      id: keyHost
      anchors.fill: parent

      // With the confirmation or the search up the catcher stands down and
      // the keys go there instead.
      Keys.onPressed: function(event) {
        if (root.confirmOpen) { if (confirmDialog.handleKey(event)) event.accepted = true; return }
        if (root.searching) { if (root.handleSearchKey(event)) event.accepted = true }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: root.confirmOpen || root.searching
        onMoveRequested: function(dx, dy) {
          if (dy !== 0) { root.moveCursor(dy); return }
          if (dx < 0 && root.focused) { root.drillOut(); return }
          var row = root.hoverRow
          if (dx > 0 && row && row.drillable) root.drillInto(row.key)
        }
        onActivateRequested: root.activate(root.hoverRow)
        onReturnRequested: root.activate(root.hoverRow)
        onDeleteRequested: root.requestClose(root.hoverRow)
        onCloseRequested: {
          if (root.query !== "") { root.query = ""; return }
          if (root.focused) root.drillOut()
          else root.close()
        }
        onTabRequested: function(direction) { root.switchPanel(direction) }
        onTextKey: function(text) {
          if (text === "/") root.searching = true
          else if (text === "s") root.setSort(Model.nextSort(root.sortKey))
          else if (text === "r") root.refresh()
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

          // ---------- Column titles: click one to sort by it ----------
          Item {
            width: parent.width
            implicitHeight: Style.space(18)

            component SortTitle: Text {
              required property string sortId
              readonly property bool current: root.sortKey === sortId
              textFormat: Text.PlainText
              text: Model.SORT_LABELS[sortId]
              color: current ? root.hotColor : root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: current
              font.letterSpacing: 1
              horizontalAlignment: Text.AlignRight
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(3)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setSort(parent.sortId)
              }
            }

            SortTitle {
              sortId: "name"
              anchors.left: parent.left
              anchors.leftMargin: tanks.width + Style.space(16) + Style.space(6)
              horizontalAlignment: Text.AlignLeft
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.colGap

              SortTitle { sortId: "cpu"; width: root.colCpu }
              SortTitle { sortId: "mem"; width: root.colMem }
              SortTitle { sortId: "gpu"; width: root.colGpu }
              SortTitle { sortId: "net"; width: root.colNet }
              Item { width: root.colClose; height: 1 }
            }
          }

          // ---------- Search line, only while there is something to show ----------
          Text {
            visible: root.searching || root.query !== ""
            textFormat: Text.PlainText
            text: "/ " + root.query + (root.searching ? "▏" : "") + (root.searching ? "" : "   esc clears")
            color: root.searching ? root.hotColor : root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            width: parent.width
            elide: Text.ElideRight
          }

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

              Tank { id: memTank; width: Style.space(18); height: parent.height; target: root.memSegments; label: "RAM" }
              Tank { id: cpuTank; width: Style.space(18); height: parent.height; target: root.cpuSegments; label: "CPU" }
              Tank { id: gpuTank; width: Style.space(18); height: parent.height; target: root.gpuSegments; label: "GPU" }
            }

            // The bands: the lit segment of each tank joined to the next,
            // and the last one joined to its row, as one continuous shape.
            // Ends follow the morphing tanks and a row position that eases,
            // so moving the cursor bends the bands rather than redrawing them.
            Item {
              id: bands
              anchors.fill: parent
              readonly property bool active: root.cursorKey !== "" && root.cursor >= 0
              property real rowTop: 0
              readonly property real targetRowTop: root.cursor >= 0 ? root.cursor * (root.rowHeight + root.rowGap) : 0
              onTargetRowTopChanged: if (active) rowTop = targetRowTop
              Behavior on rowTop { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
              opacity: active ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 180 } }

              Connections {
                target: root
                function onCursorKeyChanged() { bandCanvas.requestPaint() }
              }
              Connections { target: memTank; function onProgressChanged() { bandCanvas.requestPaint() } }
              Connections { target: cpuTank; function onProgressChanged() { bandCanvas.requestPaint() } }
              Connections { target: gpuTank; function onProgressChanged() { bandCanvas.requestPaint() } }
              onRowTopChanged: bandCanvas.requestPaint()
              onActiveChanged: { if (active) rowTop = targetRowTop; bandCanvas.requestPaint() }

              Canvas {
                id: bandCanvas
                anchors.fill: parent

                function band(ctx, x1, t1, b1, x2, t2, b2) {
                  var cx = (x1 + x2) / 2
                  ctx.beginPath()
                  ctx.moveTo(x1, t1)
                  ctx.bezierCurveTo(cx, t1, cx, t2, x2, t2)
                  ctx.lineTo(x2, b2)
                  ctx.bezierCurveTo(cx, b2, cx, b1, x1, b1)
                  ctx.closePath()
                  ctx.fillStyle = Qt.alpha(root.hotColor, 0.16)
                  ctx.fill()
                  ctx.strokeStyle = Qt.alpha(root.hotColor, 0.7)
                  ctx.lineWidth = 1
                  ctx.beginPath(); ctx.moveTo(x1, t1); ctx.bezierCurveTo(cx, t1, cx, t2, x2, t2); ctx.stroke()
                  ctx.beginPath(); ctx.moveTo(x1, b1); ctx.bezierCurveTo(cx, b1, cx, b2, x2, b2); ctx.stroke()
                }

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  if (!bands.active) return
                  var key = root.cursorKey
                  var chain = [memTank, cpuTank, gpuTank]
                  var prev = null
                  for (var i = 0; i < chain.length; i++) {
                    var tank = chain[i]
                    var span = tank.segmentSpan(key)
                    var pos = tank.mapToItem(bands, 0, 0)
                    var cur = span ? { left: pos.x, right: pos.x + tank.width, top: pos.y + span.top, bottom: pos.y + span.bottom }
                                   : { left: pos.x, right: pos.x + tank.width, top: pos.y + tank.height, bottom: pos.y + tank.height }
                    if (prev) band(ctx, prev.right, prev.top, prev.bottom, cur.left, cur.top, cur.bottom)
                    prev = cur
                  }
                  var rowX = list.x
                  var rowTop = list.y + bands.rowTop
                  band(ctx, prev.right, prev.top, prev.bottom, rowX, rowTop, rowTop + root.rowHeight)
                }
              }
            }

            Column {
              id: list
              anchors.left: tanks.right
              anchors.leftMargin: Style.space(16)
              anchors.right: parent.right
              anchors.top: parent.top
              spacing: root.rowGap

              move: Transition { NumberAnimation { properties: "y"; duration: 480; easing.type: Easing.InOutCubic } }
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
                    color: rowItem.hot ? Qt.alpha(root.hotColor, 0.16) : "transparent"
                    border.width: rowItem.hot ? 1 : 0
                    border.color: Qt.alpha(root.hotColor, 0.7)
                    Behavior on color { ColorAnimation { duration: 140 } }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: rowItem.isNote ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onPositionChanged: if (root.cursor !== rowItem.index) root.setCursor(rowItem.index)
                    onClicked: root.activate(rowItem.row)
                  }

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.right: metrics.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Item {
                      width: root.iconSize
                      height: root.iconSize
                      anchors.verticalCenter: parent.verticalCenter
                      visible: !rowItem.isNote

                      Text {
                        anchors.centerIn: parent
                        visible: rowItem.isHeader
                        textFormat: Text.PlainText
                        text: "←"
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
                    spacing: root.colGap

                    component Metric: Text {
                      textFormat: Text.PlainText
                      visible: !rowItem.isNote
                      color: root.dim
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                      horizontalAlignment: Text.AlignRight
                    }

                    Metric { width: root.colCpu; text: Model.fmtCpu(rowItem.row.cpu); color: rowItem.row.cpu >= 50 ? root.contentForeground : root.dim }
                    Metric { width: root.colMem; text: Model.fmtMem(rowItem.row.mem); color: root.contentForeground; font.pixelSize: Style.font.bodySmall }
                    Metric { width: root.colGpu; text: Model.fmtGpu(rowItem.row.gpu); color: rowItem.row.gpu >= 30 ? root.contentForeground : root.dim }
                    Metric { width: root.colNet; text: Model.fmtNet(rowItem.row.net) }

                    // Close lives at the end of the row and only shows itself
                    // on the row under the cursor: the panel reads as a
                    // report until you reach for it.
                    Item {
                      width: root.colClose
                      height: root.colClose
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
            text: root.focused ? "j k move · enter go to tab · h back · x close tab · / search · s sort"
                               : "j k move · enter go to app · l into browser · x quit · / search · s sort · b btop"
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
