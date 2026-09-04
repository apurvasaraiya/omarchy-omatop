import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The breakdown. A search field on top that is also where the keys live,
// then five rails, one per resource, RAM, CPU, GPU, DISK, NET, each split
// by app in that app's colour, then a list of up to fifty rows that
// scrolls. A row and its rail segments share a colour; hover either and
// the rails dim to that one app. Column titles sort. Enter or a click on
// an app brings its window to the front; on a browser it drills into a
// view of that browser's pages, where Enter brings the tab forward. Rows
// that can be closed get an × on hover and Ctrl+X, behind one
// confirmation that states what will be freed and what will be lost.
//
// Rails are painted on canvases that morph from the last layout to the
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

  // ---- Data
  property var snapshot: null
  property string focusKey: ""
  readonly property string query: searchField.text
  readonly property string sortKey: String(setting("sort", "mem"))
  readonly property bool focused: focusKey !== "" && rows.length > 0 && rows[0].type === "header"
  readonly property int maxApps: Math.max(5, Number(setting("maxApps", 50)) || 50)
  readonly property int visibleRows: Math.max(4, Number(setting("visibleRows", 11)) || 11)
  readonly property var rows: limitRows(Model.arrangeRows(Model.buildRows(snapshot, focusKey, 1000), sortKey, query))
  readonly property var rowMap: Model.rowMap(rows)
  readonly property var history: hostWidget && hostWidget.history ? hostWidget.history : []
  readonly property var memSegments: Model.tankSegments(snapshot, rows, "mem", visibleRows)
  readonly property var cpuSegments: Model.tankSegments(snapshot, rows, "cpu", visibleRows)
  readonly property var gpuSegments: Model.tankSegments(snapshot, rows, "gpu", visibleRows)
  readonly property var diskSegments: Model.tankSegments(snapshot, rows, "disk", visibleRows)

  // What a gauge says underneath: the machine's figure, or, with a row
  // under the cursor, that app's figure in the same unit.
  function gaugeCaption(which) {
    if (root.hoverRow && root.hoverRow.type !== "note" && root.hoverRow.type !== "header") return Model.rowFigure(root.hoverRow, which)
    return Model.railCaption(root.snapshot, which, root.rows, which === "mem" ? root.history : undefined)
  }
  readonly property var colMax: ({
    cpu: Model.columnMax(rows, "cpu"), mem: Model.columnMax(rows, "mem"), gpu: Model.columnMax(rows, "gpu"),
    disk: Model.columnMax(rows, "disk"), net: Model.columnMax(rows, "net")
  })
  readonly property var emptyRow: ({ type: "note", key: "", parentKey: "", name: "", comm: "", subtitle: "", mem: 0, cpu: 0, gpu: 0, net: 0, disk: 0, age: 0, count: 0, pids: [], root: 0, protectedRow: true, drillable: false, closable: false, browser: false, devtools: "", profile: "", targets: [], omarchy: false, icon: "", iconName: "", depth: 0 })

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
  onRowsChanged: {
    syncKeys(rowModel, Model.keysOf(rows))
    pointerGate.reset()
  }

  // A delegate created or moved under a resting pointer reports a hover it
  // never earned. The gate only lets deliberate pointer travel move the
  // cursor; keys and samples reset it.
  PointerMoveGate { id: pointerGate; referenceItem: column; threshold: 2 }

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

  // ---- Cursor: shared by keyboard, rows and rail segments. -1 is "nothing yet".
  property int cursor: -1
  property string cursorKey: ""
  // A selection made by the pointer lets go when the pointer leaves the
  // panel's body; one made by the keys stays until Esc.
  property bool cursorByPointer: false
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
  readonly property color accent: Color.accent

  readonly property int rowHeight: Style.spacing.popupRowHeight + Style.space(6)
  readonly property int rowGap: Style.space(2)
  readonly property int iconSize: Style.space(16)
  readonly property int colCpu: Style.space(40)
  readonly property int colMem: Style.space(56)
  readonly property int colGpu: Style.space(40)
  readonly property int colDisk: Style.space(64)
  readonly property int colNet: Style.space(58)
  readonly property int colClose: Style.space(18)
  readonly property int colGap: Style.space(10)

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

  // For the IPC: where the cursor is, for checking the panel from a shell.
  function debugState() {
    return JSON.stringify({ cursor: root.cursor, cursorKey: root.cursorKey, rows: root.rows.length, focus: root.focusKey, sort: root.sortKey, query: root.query })
  }

  // ---- Cursor moves
  function moveCursor(delta) {
    pointerGate.reset()
    root.cursorByPointer = false
    if (root.rows.length === 0) return
    var next = root.cursor < 0 ? (delta > 0 ? 0 : root.rows.length - 1) : Model.clampIndex(root.cursor + delta, root.rows.length)
    setCursor(next)
    list.positionViewAtIndex(next, ListView.Contain)
  }

  function setCursor(index) {
    root.cursor = index
    root.cursorKey = index >= 0 && index < root.rows.length ? root.rows[index].key : ""
  }

  function setCursorKey(key) {
    var idx = Model.indexOfKey(root.rows, key)
    if (idx >= 0 && idx !== root.cursor) {
      setCursor(idx)
      list.positionViewAtIndex(idx, ListView.Contain)
    }
  }

  function pointerCursor(index) {
    root.cursorByPointer = true
    setCursor(index)
  }

  function pointerCursorKey(key) {
    root.cursorByPointer = true
    setCursorKey(key)
  }

  function clearCursor() {
    root.cursor = -1
    root.cursorKey = ""
    root.cursorByPointer = false
  }

  function releasePointerCursor() {
    if (root.cursorByPointer && !root.confirmOpen) clearCursor()
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
    searchField.text = ""
    clearCursor()
  }

  function drillOut() {
    var back = root.focusKey
    root.focusKey = ""
    searchField.text = ""
    Qt.callLater(function() { if (back !== "") setCursorKey(back) })
  }

  // For the IPC: land on a row by key and ask to close it, so the whole
  // quit flow can be driven (and tested) without a pointer.
  function requestCloseKey(key) {
    if (!root.opened) root.open()
    setCursorKey(key)
    requestClose(root.rowMap[key] || null)
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
      return stillRunning(row) ? "still running · ⌃X again to force" : "quitting…"
    }
    return ""
  }

  // ---- Keys. The search field holds focus, so letters search. Everything
  //      else is caught before the field sees it.
  function handleKey(event) {
    if (root.confirmOpen) return confirmDialog.handleKey(event)
    var ctrl = event.modifiers & Qt.ControlModifier
    if (event.key === Qt.Key_Down || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N))) { moveCursor(1); return true }
    if (event.key === Qt.Key_Up || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P))) { moveCursor(-1); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { activate(root.hoverRow); return true }
    if (event.key === Qt.Key_Tab) { setSort(Model.nextSort(root.sortKey)); return true }
    if (ctrl && event.key === Qt.Key_X) { requestClose(root.hoverRow); return true }
    if (event.key === Qt.Key_Delete && searchField.text === "") { requestClose(root.hoverRow); return true }
    if (event.key === Qt.Key_Escape) {
      if (root.cursor >= 0) clearCursor()
      else if (searchField.text !== "") searchField.text = ""
      else if (root.focused) drillOut()
      else root.close()
      return true
    }
    if (searchField.text === "") {
      if (event.key === Qt.Key_Left && root.focused) { drillOut(); return true }
      if (event.key === Qt.Key_Right && root.hoverRow && root.hoverRow.drillable) { drillInto(root.hoverRow.key); return true }
    }
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

  readonly property string browserIconSource: appIconSource("chromium")

  onOpenedChanged: {
    if (opened) {
      root.lastError = ""
      pointerGate.reset()
      watchProc.running = true
    } else {
      watchProc.running = false
      clearCursor()
      root.focusKey = ""
      searchField.text = ""
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
    interval: 200
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
      if (code === 3 && goProc.fallbackToTop && root.bar) { root.bar.run("omarchy-launch-tui btop"); return }
      if (root.bar) root.bar.run("omarchy-notification-send \"Omatop could not bring that to front\"")
    }
  }

  Timer {
    interval: 1000
    running: root.opened && Object.keys(root.pendingQuits).length > 0
    repeat: true
    onTriggered: root.pendingQuits = Object.assign({}, root.pendingQuits)
  }

  // ---- A gauge: a rounded column filled bottom-up with one segment per
  //      row in that row's colour, painted on a canvas that morphs between
  //      layouts. Five of them stand in a row above the list, a skyline of
  //      what is full. With a row under the cursor the rest of each gauge
  //      dims to that one app.
  component Gauge: Item {
    id: gaugeItem
    property var target: []
    property string label: ""
    property string caption: ""
    property var shown: []
    property var shownMap: ({})
    property var fromMap: ({})
    property real progress: 1

    readonly property int tubeWidth: Style.space(64)
    readonly property int tubeHeight: Style.space(116)
    readonly property real innerHeight: Math.max(0, tubeHeight - 2)
    implicitHeight: tubeHeight + Style.space(6) + labelText.implicitHeight + Style.space(2) + captionText.implicitHeight

    onTargetChanged: {
      gaugeItem.fromMap = gaugeItem.shownMap
      gaugeItem.progress = 0
      morph.restart()
    }

    NumberAnimation {
      id: morph
      target: gaugeItem
      property: "progress"
      from: 0
      to: 1
      duration: 800
      easing.type: Easing.InOutCubic
    }

    onProgressChanged: repaint()

    function repaint() {
      var next = Model.morphSegments(gaugeItem.fromMap, gaugeItem.target, gaugeItem.progress)
      var m = {}
      for (var i = 0; i < next.length; i++) m[next[i].key] = next[i]
      gaugeItem.shown = next
      gaugeItem.shownMap = m
      canvas.requestPaint()
    }

    function keyAt(y) {
      for (var i = 0; i < gaugeItem.shown.length; i++) {
        var s = gaugeItem.shown[i]
        if (s.key === "rest") continue
        var top = 1 + gaugeItem.innerHeight * (1 - s.start - s.frac)
        if (y >= top && y <= top + gaugeItem.innerHeight * s.frac) return s.key
      }
      return ""
    }

    // Top and bottom of a segment in this item's coordinates, or null.
    function segmentSpan(key) {
      var s = gaugeItem.shownMap[key]
      if (!s) return null
      var top = 1 + gaugeItem.innerHeight * (1 - s.start - s.frac)
      return { top: top, bottom: top + gaugeItem.innerHeight * s.frac }
    }
    readonly property real tubeLeft: (width - tubeWidth) / 2

    Connections {
      target: root
      function onCursorKeyChanged() { canvas.requestPaint() }
    }

    Canvas {
      id: canvas
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      width: gaugeItem.tubeWidth
      height: gaugeItem.tubeHeight

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var w = width, h = height
        var r = Math.min(Style.cornerRadius + 2, w / 2)
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
        ctx.fillStyle = Qt.alpha(fg, 0.06)
        ctx.fill()
        ctx.save()
        ctx.clip()

        var hovering = root.cursorKey !== ""
        var inner = gaugeItem.innerHeight
        for (var i = 0; i < gaugeItem.shown.length; i++) {
          var s = gaugeItem.shown[i]
          var top = 1 + inner * (1 - s.start - s.frac)
          var sh = inner * s.frac
          if (sh < 0.5) continue
          var hot = hovering && s.key === root.cursorKey
          var col, alpha
          if (s.key === "rest") { col = fg; alpha = 0.16 }
          else { col = Model.colorFor(s.key); alpha = 0.92 }
          if (hovering && !hot) alpha *= 0.22
          ctx.fillStyle = Qt.alpha(col, alpha)
          ctx.fillRect(1, top, w - 2, Math.max(0.5, sh - 1))
        }
        ctx.restore()

        rounded(0.5, 0.5, w - 1, h - 1, r)
        ctx.strokeStyle = Qt.alpha(fg, 0.2)
        ctx.lineWidth = 1
        ctx.stroke()
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: function(mouse) {
          if (!pointerGate.moved(gaugeItem, mouse)) return
          var key = gaugeItem.keyAt(mouse.y)
          if (key !== "") root.pointerCursorKey(key)
          else root.releasePointerCursor()
        }
        onClicked: function(mouse) {
          var key = gaugeItem.keyAt(mouse.y)
          if (key !== "") root.activate(root.rowMap[key] || null)
        }
      }
    }

    Text {
      id: labelText
      anchors.top: canvas.bottom
      anchors.topMargin: Style.space(6)
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: gaugeItem.label
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }

    Text {
      id: captionText
      anchors.top: labelText.bottom
      anchors.topMargin: Style.space(2)
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: gaugeItem.caption
      color: root.dim
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      width: parent.width
      elide: Text.ElideRight
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: panel.fittedContentWidth(Style.space(660))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing

    Item {
      id: keyHost
      anchors.fill: parent

      // Leaving the gauges and the list, into the field, the titles or off
      // the panel, lets a pointer selection go after a beat, so the
      // machine's own figures come back without a gesture.
      readonly property bool bodyHovered: gaugesHover.hovered || listHover.hovered
      onBodyHoveredChanged: if (!bodyHovered) releaseTimer.restart(); else releaseTimer.stop()
      Timer {
        id: releaseTimer
        interval: 220
        onTriggered: root.releasePointerCursor()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Search, and the keyboard ----------
        TextField {
          id: searchField
          width: parent.width
          foreground: root.contentForeground
          accent: root.accent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          placeholderText: root.focused
            ? "Search pages   ↑↓ move · ⏎ go to tab · ← back · ⌃X close tab"
            : "Search apps and sites   ↑↓ move · ⏎ open · → into browser · ⌃X quit · ⇥ sort"
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { if (root.handleKey(event)) event.accepted = true }
          onTextChanged: { root.clearCursor(); list.positionViewAtBeginning() }
        }

        // ---------- Gauges: five columns standing together ----------
        Item {
          width: parent.width
          implicitHeight: gauges.implicitHeight
          HoverHandler { id: gaugesHover }

          // The ribbons: with a row under the cursor, its segment in each
          // gauge is joined to the same segment in the next, in the row's
          // colour, so one app reads across the strip as one shape. They
          // exist only while hovering; the strip stays quiet otherwise.
          Item {
            id: ribbons
            anchors.fill: parent
            readonly property bool active: root.cursorKey !== "" && root.cursor >= 0
            opacity: active ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180 } }

            Connections { target: root; function onCursorKeyChanged() { ribbonCanvas.requestPaint() } }
            Timer {
              // Gauges morph for 800 ms after a sample; keep the ribbons on them.
              interval: 40
              running: ribbons.active
              repeat: true
              onTriggered: ribbonCanvas.requestPaint()
            }

            Canvas {
              id: ribbonCanvas
              anchors.fill: parent

              function ribbon(ctx, col, x1, t1, b1, x2, t2, b2) {
                var cx = (x1 + x2) / 2
                ctx.beginPath()
                ctx.moveTo(x1, t1)
                ctx.bezierCurveTo(cx, t1, cx, t2, x2, t2)
                ctx.lineTo(x2, b2)
                ctx.bezierCurveTo(cx, b2, cx, b1, x1, b1)
                ctx.closePath()
                ctx.fillStyle = Qt.alpha(col, 0.16)
                ctx.fill()
                ctx.strokeStyle = Qt.alpha(col, 0.7)
                ctx.lineWidth = 1
                ctx.beginPath(); ctx.moveTo(x1, t1); ctx.bezierCurveTo(cx, t1, cx, t2, x2, t2); ctx.stroke()
                ctx.beginPath(); ctx.moveTo(x1, b1); ctx.bezierCurveTo(cx, b1, cx, b2, x2, b2); ctx.stroke()
              }

              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                if (!ribbons.active) return
                var key = root.cursorKey
                var col = Model.colorFor(key)
                var chain = [memGauge, cpuGauge, gpuGauge, diskGauge]
                var prev = null
                for (var i = 0; i < chain.length; i++) {
                  var g = chain[i]
                  var span = g.segmentSpan(key)
                  var pos = g.mapToItem(ribbons, g.tubeLeft, 0)
                  var bottom = pos.y + g.tubeHeight
                  var cur = span ? { left: pos.x, right: pos.x + g.tubeWidth, top: pos.y + span.top, bottom: pos.y + span.bottom }
                                 : { left: pos.x, right: pos.x + g.tubeWidth, top: bottom, bottom: bottom }
                  if (prev) ribbon(ctx, col, prev.right, prev.top, prev.bottom, cur.left, cur.top, cur.bottom)
                  prev = cur
                }
              }
            }
          }

        Row {
          id: gauges
          width: parent.width
          readonly property int cell: Math.floor(width / 5)

          Gauge { id: memGauge; width: gauges.cell; target: root.memSegments; label: "RAM"; caption: root.gaugeCaption("mem") }
          Gauge { id: cpuGauge; width: gauges.cell; target: root.cpuSegments; label: "CPU"; caption: root.gaugeCaption("cpu") }
          Gauge { id: gpuGauge; width: gauges.cell; target: root.gpuSegments; label: "GPU"; caption: root.gaugeCaption("gpu") }
          Gauge { id: diskGauge; width: gauges.cell; target: root.diskSegments; label: "DISK"; caption: root.gaugeCaption("disk") }

          // The network gauge is the machine's, not split by app: the kernel
          // does not say which process a byte belonged to. Two columns in
          // one tube, down beside up, against a 10 MB/s scale.
          Item {
            id: netGauge
            width: gauges.cell
            height: gauges.height
            readonly property var fr: Model.netFractions(root.snapshot)
            readonly property int tubeWidth: Style.space(64)
            readonly property int tubeHeight: Style.space(116)

            Rectangle {
              id: netTube
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              width: netGauge.tubeWidth
              height: netGauge.tubeHeight
              radius: Math.min(Style.cornerRadius + 2, width / 2)
              color: Qt.alpha(root.contentForeground, 0.06)
              border.width: 1
              border.color: Qt.alpha(root.contentForeground, 0.2)
              clip: true

              Row {
                anchors.fill: parent
                anchors.margins: 1
                spacing: 1

                Repeater {
                  model: [netGauge.fr.down, netGauge.fr.up]
                  Item {
                    required property var modelData
                    required property int index
                    width: (parent.width - 1) / 2
                    height: parent.height
                    Rectangle {
                      anchors.bottom: parent.bottom
                      width: parent.width
                      height: Math.max(0, Math.round(parent.height * modelData))
                      color: Qt.alpha(root.accent, index === 0 ? 0.9 : 0.5)
                      Behavior on height { NumberAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                    }
                    Text {
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Style.space(3)
                      anchors.horizontalCenter: parent.horizontalCenter
                      textFormat: Text.PlainText
                      text: index === 0 ? "↓" : "↑"
                      color: Qt.alpha(root.contentForeground, 0.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            Text {
              id: netLabel
              anchors.top: netTube.bottom
              anchors.topMargin: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "NET"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }

            Text {
              anchors.top: netLabel.bottom
              anchors.topMargin: Style.space(2)
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.gaugeCaption("net")
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
              elide: Text.ElideRight
            }
          }
        }

        }

        // ---------- Column titles: click one to sort by it ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(16)

          component SortTitle: Text {
            required property string sortId
            readonly property bool current: root.sortKey === sortId
            textFormat: Text.PlainText
            text: Model.SORT_LABELS[sortId]
            color: current ? root.accent : Qt.alpha(root.dim, 0.8)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: current
            font.letterSpacing: 1
            horizontalAlignment: Text.AlignRight
            anchors.verticalCenter: parent.verticalCenter

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setSort(parent.sortId)
            }
          }

          SortTitle {
            sortId: "name"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6) + Style.space(6) + root.iconSize + Style.space(8)
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
            SortTitle { sortId: "disk"; width: root.colDisk }
            SortTitle { sortId: "net"; width: root.colNet }
            Item { width: root.colClose; height: 1 }
          }
        }

        // ---------- Rows, in a window that scrolls ----------
        ListView {
          id: list
          width: parent.width
          // As tall as the rows, up to the window; the browser view with
          // three pages does not drag an empty list behind it.
          height: Math.max(1, Math.min(root.visibleRows, rowModel.count)) * (root.rowHeight + root.rowGap) - root.rowGap
          Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
          clip: true
          model: rowModel
          spacing: root.rowGap
          boundsBehavior: Flickable.StopAtBounds
          flickDeceleration: 4000
          maximumFlickVelocity: 3000

          HoverHandler { id: listHover }

          move: Transition { NumberAnimation { properties: "y"; duration: 480; easing.type: Easing.InOutCubic } }
          displaced: Transition { NumberAnimation { properties: "y"; duration: 480; easing.type: Easing.InOutCubic } }
          add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 } }

          // A quiet scroll mark on the right, only when there is more.
          Rectangle {
            visible: list.contentHeight > list.height
            anchors.right: parent.right
            width: 2
            radius: 1
            y: list.contentHeight > 0 ? list.height * (list.contentY / list.contentHeight) : 0
            height: list.contentHeight > 0 ? Math.max(Style.space(12), list.height * (list.height / list.contentHeight)) : 0
            color: Qt.alpha(root.contentForeground, 0.25)
          }

          delegate: Item {
            id: rowItem
            required property string key
            required property int index
            readonly property var row: root.rowMap[key] || root.emptyRow
            readonly property bool hot: root.cursor === index
            readonly property bool isNote: row.type === "note"
            readonly property bool isHeader: row.type === "header"
            readonly property color tone: Model.colorFor(key)
            readonly property string status: root.rowStatus(row)
            readonly property bool showClose: row.closable && (hot || closeMouse.containsMouse)
            readonly property string iconSource: root.rowIconSource(row)

            width: ListView.view ? ListView.view.width : 0
            height: root.rowHeight

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: rowItem.hot ? Qt.alpha(rowItem.tone, 0.14) : "transparent"
              border.width: rowItem.hot ? 1 : 0
              border.color: Qt.alpha(rowItem.tone, 0.6)
              Behavior on color { ColorAnimation { duration: 140 } }
            }

            // The row's colour, the same one its rail segments wear.
            Rectangle {
              visible: !rowItem.isNote && !rowItem.isHeader
              anchors.left: parent.left
              anchors.leftMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              width: 3
              height: parent.height - Style.space(10)
              radius: 1.5
              color: Qt.alpha(rowItem.tone, rowItem.hot || root.cursorKey === "" ? 0.95 : 0.35)
              Behavior on color { ColorAnimation { duration: 140 } }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: rowItem.isNote ? Qt.ArrowCursor : Qt.PointingHandCursor
              onPositionChanged: function(mouse) {
                if (pointerGate.moved(rowItem, mouse) && root.cursor !== rowItem.index) root.pointerCursor(rowItem.index)
              }
              onClicked: root.activate(rowItem.row)
            }

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
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
                  color: Qt.alpha(rowItem.tone, 0.25)

                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: rowItem.row.name ? rowItem.row.name.charAt(0).toUpperCase() : ""
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                // An Omarchy web app is a Chromium window wearing the
                // app's icon; the badge says so.
                Image {
                  visible: rowItem.row.omarchy && status === Image.Ready
                  source: rowItem.row.omarchy ? root.browserIconSource : ""
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: -3
                  width: Style.space(10)
                  height: Style.space(10)
                  sourceSize.width: Style.space(20)
                  sourceSize.height: Style.space(20)
                  fillMode: Image.PreserveAspectFit
                  smooth: true
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
                color: rowItem.status !== "" && root.stillRunning(rowItem.row) ? root.urgentColor : root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                width: Math.max(0, parent.width - x)
              }
            }

            // Each figure sits over a hairline bar scaled to the column's
            // largest value, so a column reads as a chart without reading.
            Row {
              id: metrics
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.colGap

              component Metric: Item {
                property string value: ""
                property real share: 0
                property bool strong: false
                visible: !rowItem.isNote
                height: root.rowHeight
                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: -Style.space(2)
                  textFormat: Text.PlainText
                  text: parent.value
                  color: parent.strong ? root.contentForeground : root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Rectangle {
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(5)
                  height: 2
                  radius: 1
                  width: Math.round(parent.width * Math.max(0, Math.min(1, parent.share)))
                  color: Qt.alpha(rowItem.hot ? rowItem.tone : root.contentForeground, rowItem.hot ? 0.9 : 0.3)
                  Behavior on width { NumberAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                }
              }

              Metric { width: root.colCpu; value: Model.fmtCpu(rowItem.row.cpu); share: root.colMax.cpu > 0 ? rowItem.row.cpu / root.colMax.cpu : 0; strong: rowItem.row.cpu >= 50 }
              Metric { width: root.colMem; value: Model.fmtMem(rowItem.row.mem); share: root.colMax.mem > 0 ? rowItem.row.mem / root.colMax.mem : 0; strong: true }
              Metric { width: root.colGpu; value: Model.fmtGpu(rowItem.row.gpu); share: root.colMax.gpu > 0 ? rowItem.row.gpu / root.colMax.gpu : 0; strong: rowItem.row.gpu >= 30 }
              Metric { width: root.colDisk; value: Model.fmtDisk(rowItem.row.disk); share: root.colMax.disk > 0 ? rowItem.row.disk / root.colMax.disk : 0; strong: rowItem.row.disk >= 1048576 }
              Metric { width: root.colNet; value: Model.fmtNet(rowItem.row.net); share: root.colMax.net > 0 ? rowItem.row.net / root.colMax.net : 0 }

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
                  onPositionChanged: function(mouse) {
                    if (pointerGate.moved(rowItem, mouse) && root.cursor !== rowItem.index) root.pointerCursor(rowItem.index)
                  }
                  onClicked: root.requestClose(rowItem.row)
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
