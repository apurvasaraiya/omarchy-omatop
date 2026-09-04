.pragma library

// Pure helpers for the Omatop panel: formatting, the hero sentence, the
// flattening of a snapshot into rows, and the tank segments the rows link
// to. Nothing in here touches QML objects, so it can be reasoned about (and
// tested) on its own. It is a QML library, so edits need a shell restart.

function fmtMem(kb) {
  var n = Number(kb) || 0
  if (n >= 1024 * 1024) return (n / (1024 * 1024)).toFixed(n >= 10 * 1024 * 1024 ? 0 : 1) + " GB"
  if (n >= 1024) return Math.round(n / 1024) + " MB"
  return Math.round(n) + " kB"
}

function fmtCpu(pct) {
  var n = Number(pct) || 0
  return Math.round(n) + "%"
}

function fmtGpu(pct) {
  var n = Number(pct) || 0
  return Math.round(n) + "%"
}

function fmtNet(count) {
  return String(Number(count) || 0)
}

// Disk in the row, with its unit; under a kilobyte a second is a zero.
function fmtDisk(bytesPerSec) {
  var n = Number(bytesPerSec) || 0
  if (n < 1024) return "0 kB/s"
  if (n < 1024 * 1024) return Math.round(n / 1024) + " kB/s"
  return (n / (1024 * 1024)).toFixed(1) + " MB/s"
}

function fmtRate(bytesPerSec) {
  var n = Number(bytesPerSec) || 0
  if (n < 1024) return "0 kB/s"
  if (n < 1024 * 1024) return Math.round(n / 1024) + " kB/s"
  return (n / (1024 * 1024)).toFixed(1) + " MB/s"
}

function fmtLoad(load) {
  if (!load || load.length < 1) return ""
  return (Number(load[0]) || 0).toFixed(1)
}

// Ages read like a person says them: "40m", "5h", "2d". Under a minute is
// nothing worth printing.
function fmtAge(sec) {
  var n = Number(sec) || 0
  if (n < 60) return ""
  if (n < 3600) return Math.round(n / 60) + "m"
  if (n < 86400) return (n < 36000 ? (n / 3600).toFixed(1).replace(/\.0$/, "") : Math.round(n / 3600)) + "h"
  return Math.round(n / 86400) + "d"
}

function share(kb, totalKb) {
  var t = Number(totalKb) || 0
  if (t <= 0) return 0
  return Math.max(0, Math.min(1, (Number(kb) || 0) / t))
}

function usedFraction(snapshot) {
  if (!snapshot || !snapshot.mem) return 0
  return share(snapshot.mem.used, snapshot.mem.total)
}

function loadFraction(snapshot) {
  if (!snapshot || !snapshot.load || !snapshot.ncpu) return 0
  return (Number(snapshot.load[0]) || 0) / snapshot.ncpu
}

// Under this much headroom the kernel starts reclaiming aggressively and
// the laptop feels it: that is the line between "busy" and "tight".
var TIGHT_FRACTION = 0.12

function isTight(snapshot) {
  if (!snapshot || !snapshot.mem || !snapshot.mem.total) return false
  return snapshot.mem.available / snapshot.mem.total < TIGHT_FRACTION
}

// The bar's states from the cheap sample: calm, busy, cpu (the processor is
// what is saturated, memory is fine) and hot (memory nearly gone).
function barState(snapshot) {
  if (!snapshot || !snapshot.mem) return "calm"
  if (isTight(snapshot)) return "hot"
  if (loadFraction(snapshot) >= 0.9) return "cpu"
  if (usedFraction(snapshot) >= 0.75 || loadFraction(snapshot) >= 0.5) return "busy"
  return "calm"
}

function topApp(snapshot) {
  return snapshot && snapshot.apps && snapshot.apps.length > 0 ? snapshot.apps[0] : null
}

function topSite(app) {
  if (!app || !app.sites) return null
  for (var i = 0; i < app.sites.length; i++) {
    if (app.sites[i].kind === "site") return app.sites[i]
  }
  return null
}

function siteLabel(site) {
  return site.omarchy ? site.app : site.name
}

// The biggest thing that can actually be closed: a page if the top app is a
// browser with sites resolved, else the heaviest unprotected app.
function bestRelease(snapshot) {
  if (!snapshot || !snapshot.apps) return null
  for (var i = 0; i < snapshot.apps.length; i++) {
    var app = snapshot.apps[i]
    if (app.protected) continue
    var site = topSite(app)
    if (app.browser && site && site.closable) return { name: siteLabel(site), mem: site.mem }
    return { name: app.name, mem: app.mem }
  }
  return null
}

// The one sentence the panel opens with. It names the culprit when there is
// one, tells you what to close when memory is tight, and says so when
// nothing dominates, so the reader never has to scan.
function heroTitle(snapshot) {
  var top = topApp(snapshot)
  if (!snapshot || snapshot.light || !top) return "Reading…"
  if (isTight(snapshot)) {
    var rel = bestRelease(snapshot)
    if (rel) return "Tight. Closing " + rel.name + " frees " + fmtMem(rel.mem)
    return "Memory is tight"
  }
  var used = snapshot.mem.used
  if (share(top.mem, used) >= 0.3) {
    var line = top.name + " holds " + fmtMem(top.mem)
    var site = topSite(top)
    if (site && share(site.mem, top.mem) >= 0.35) line += ", mostly " + siteLabel(site)
    return line
  }
  return top.name + " leads at " + fmtMem(top.mem) + ", no hog"
}

function heroMeta(snapshot) {
  if (!snapshot || !snapshot.mem) return ""
  var m = snapshot.mem
  var parts = [fmtMem(m.used) + " of " + fmtMem(m.total)]
  if (isTight(snapshot)) parts.push("only " + fmtMem(m.available) + " free")
  parts.push("cpu " + Math.round(Math.min(1, loadFraction(snapshot)) * 100) + "%")
  if (snapshot.gpu !== undefined && Number(snapshot.gpu) >= 1) parts.push("gpu " + Math.round(snapshot.gpu) + "%")
  if (snapshot.net) parts.push("↓" + fmtRate(snapshot.net.down) + " ↑" + fmtRate(snapshot.net.up))
  return parts.join(" · ")
}

// The bar's hover: the two numbers, nothing else.
function barTooltip(snapshot) {
  if (!snapshot || !snapshot.mem) return ""
  return "CPU " + Math.round(Math.min(1, loadFraction(snapshot)) * 100) + "% · RAM " + fmtMem(snapshot.mem.used)
}

// Rows the panel paints, top to bottom. Two views: the ten heaviest apps,
// or, focused on a browser, that browser as a header and every page it
// holds, then one row for the browser itself. No "and n more": what does
// not make the cut is not what is slowing the machine.
var MAX_PAGES = 10

function findApp(snapshot, key) {
  if (!snapshot || !snapshot.apps) return null
  for (var i = 0; i < snapshot.apps.length; i++) if (snapshot.apps[i].key === key) return snapshot.apps[i]
  return null
}

function appRow(app, asHeader) {
  return {
    type: asHeader ? "header" : "app",
    key: app.key,
    parentKey: "",
    name: app.name,
    comm: app.comm || "",
    subtitle: asHeader ? "" : appSubtitle(app),
    mem: app.mem,
    cpu: app.cpu,
    gpu: app.gpu || 0,
    net: app.net || 0,
    disk: app.disk || 0,
    age: app.age || 0,
    count: app.count || 1,
    pids: app.pids,
    root: app.root,
    protectedRow: app.protected === true,
    drillable: !!(app.browser && app.sites && app.sites.length > 0),
    closable: app.protected !== true && !asHeader,
    browser: app.browser === true,
    devtools: app.devtools || "",
    profile: app.profile || "",
    targets: [],
    omarchy: false,
    icon: "",
    iconName: "",
    depth: 0
  }
}

function appSubtitle(app) {
  if (app.browser && app.sites) {
    var pages = 0
    var webapps = 0
    for (var i = 0; i < app.sites.length; i++) {
      if (app.sites[i].kind !== "site") continue
      if (app.sites[i].omarchy) webapps++
      else pages++
    }
    var parts = []
    if (pages > 0) parts.push(pages + (pages === 1 ? " page" : " pages"))
    if (webapps > 0) parts.push(webapps + " Omarchy " + (webapps === 1 ? "app" : "apps") + " above")
    if (parts.length > 0) return parts.join(" · ")
  }
  return app.title || (app.count > 1 ? app.count + " processes" : "")
}

// An Omarchy web app is a Chromium window, but it lives on the desktop as
// an app, so it is listed as one: its own row, in its own colour, with the
// browser's row holding what is left.
function webAppRow(app, page) {
  return {
    type: "site",
    key: app.key + "/" + page.key,
    parentKey: "",
    name: siteLabel(page),
    comm: "",
    subtitle: "Omarchy app · " + page.name + (page.tabs > 1 ? " · " + page.tabs + " windows" : ""),
    mem: page.mem,
    cpu: page.cpu,
    gpu: page.gpu || 0,
    net: page.net || 0,
    disk: page.disk || 0,
    age: page.age || 0,
    count: page.pids.length,
    pids: page.pids,
    root: 0,
    protectedRow: false,
    drillable: false,
    closable: page.closable === true && page.targets.length > 0,
    browser: false,
    devtools: "",
    profile: app.profile || "",
    targets: page.targets,
    omarchy: true,
    icon: page.icon || "",
    iconName: page.iconName || "",
    depth: 0
  }
}

function withoutWebApps(app) {
  if (!app.browser || !app.sites) return app
  var rest = Object.assign({}, app)
  for (var i = 0; i < app.sites.length; i++) {
    var site = app.sites[i]
    if (site.kind !== "site" || !site.omarchy) continue
    rest.mem = Math.max(0, rest.mem - site.mem)
    rest.cpu = Math.max(0, rest.cpu - site.cpu)
    rest.gpu = Math.max(0, (rest.gpu || 0) - (site.gpu || 0))
    rest.net = Math.max(0, (rest.net || 0) - (site.net || 0))
    rest.disk = Math.max(0, (rest.disk || 0) - (site.disk || 0))
    rest.count = Math.max(1, (rest.count || 1) - site.pids.length)
  }
  return rest
}

function buildRows(snapshot, focusKey, maxApps) {
  var rows = []
  if (!snapshot || !snapshot.apps) return rows
  var focused = focusKey !== "" ? findApp(snapshot, focusKey) : null
  if (focused) {
    rows.push(appRow(withoutWebApps(focused), true))
    appendBrowserRows(rows, focused)
    return rows
  }
  var apps = snapshot.apps
  var limit = Math.min(apps.length, maxApps)
  for (var i = 0; i < limit; i++) {
    var app = apps[i]
    rows.push(appRow(withoutWebApps(app), false))
    if (app.browser && app.sites) {
      for (var j = 0; j < app.sites.length; j++) {
        if (app.sites[j].kind === "site" && app.sites[j].omarchy) rows.push(webAppRow(app, app.sites[j]))
      }
    }
  }
  return rows
}

function appendBrowserRows(rows, app) {
  var pages = []
  var selfPids = []
  var selfMem = 0
  var selfCpu = 0
  var selfGpu = 0
  var selfNet = 0
  var selfDisk = 0
  for (var j = 0; j < app.sites.length; j++) {
    var site = app.sites[j]
    if (site.kind === "site") { if (!site.omarchy) pages.push(site) }
    else {
      selfPids = selfPids.concat(site.pids)
      selfMem += site.mem
      selfCpu += site.cpu
      selfGpu += site.gpu || 0
      selfNet += site.net || 0
      selfDisk += site.disk || 0
    }
  }
  for (var k = 0; k < Math.min(pages.length, MAX_PAGES); k++) {
    var page = pages[k]
    rows.push({
      type: "site",
      key: app.key + "/" + page.key,
      parentKey: app.key,
      name: siteLabel(page),
      comm: "",
      subtitle: siteSubtitle(page),
      mem: page.mem,
      cpu: page.cpu,
      gpu: page.gpu || 0,
      net: page.net || 0,
      disk: page.disk || 0,
      age: page.age || 0,
      count: page.pids.length,
      pids: page.pids,
      root: 0,
      protectedRow: false,
      drillable: false,
      closable: page.closable === true && page.targets.length > 0,
      browser: false,
      devtools: "",
      profile: app.profile || "",
      targets: page.targets,
      omarchy: page.omarchy === true,
      icon: page.icon || "",
      iconName: page.iconName || "",
      depth: 1
    })
  }
  if (selfPids.length > 0) {
    rows.push({
      type: "bucket",
      key: app.key + "/self",
      parentKey: app.key,
      name: app.name + " itself",
      comm: app.comm || "",
      subtitle: "extensions, GPU, network, background pages",
      mem: selfMem,
      cpu: Math.round(selfCpu * 10) / 10,
      gpu: Math.round(selfGpu * 10) / 10,
      net: selfNet,
      disk: selfDisk,
      age: 0,
      count: selfPids.length,
      pids: selfPids,
      root: 0, protectedRow: false, drillable: false,
      closable: false, browser: false, devtools: "", profile: "", targets: [],
      omarchy: false, icon: "", iconName: "", depth: 1
    })
  }
  if (app.devtools !== "ok") {
    rows.push({
      type: "note",
      key: app.key + "/note",
      parentKey: app.key,
      name: devtoolsNote(app.devtools),
      comm: "",
      subtitle: "", mem: 0, cpu: 0, gpu: 0, net: 0, disk: 0, age: 0, count: 0, pids: [], root: 0, protectedRow: true,
      drillable: false, closable: false, browser: false,
      devtools: "", profile: "", targets: [], omarchy: false, icon: "", iconName: "", depth: 1
    })
  }
}

// ---- Sorting and search. The header stays first and the browser's own
// row last; everything between sorts by the chosen column. A query keeps
// the rows whose name or subtitle contains it.
var SORTS = ["mem", "cpu", "gpu", "disk", "net", "name"]
var SORT_LABELS = { mem: "RAM", cpu: "CPU", gpu: "GPU", disk: "DISK", net: "SOCKETS", name: "APP" }

function nextSort(current) {
  var i = SORTS.indexOf(current)
  return SORTS[(i + 1) % SORTS.length]
}

function arrangeRows(rows, sortKey, query) {
  var q = String(query || "").toLowerCase().trim()
  var head = []
  var body = []
  var tail = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r.type === "header") { head.push(r); continue }
    if (r.type === "note") { tail.push(r); continue }
    if (q !== "" && r.type !== "bucket" && (r.name + " " + r.subtitle).toLowerCase().indexOf(q) < 0) continue
    if (r.type === "bucket") tail.unshift(r)
    else body.push(r)
  }
  var keyed = body.map(function(r, idx) { return { r: r, idx: idx } })
  keyed.sort(function(a, b) {
    var d
    if (sortKey === "name") d = a.r.name.toLowerCase() < b.r.name.toLowerCase() ? -1 : (a.r.name.toLowerCase() > b.r.name.toLowerCase() ? 1 : 0)
    else d = (Number(b.r[sortKey]) || 0) - (Number(a.r[sortKey]) || 0)
    return d !== 0 ? d : a.idx - b.idx
  })
  return head.concat(keyed.map(function(k) { return k.r }), tail)
}

function siteSubtitle(site) {
  var parts = []
  if (site.omarchy) parts.push("Omarchy app")
  if (site.tabs > 1) parts.push(site.tabs + " tabs")
  else if (site.omarchy) parts.push(site.name)
  else if (site.title) parts.push(site.title)
  var age = fmtAge(site.age)
  if (age !== "") parts.push(age)
  return parts.join(" · ")
}

function devtoolsNote(status) {
  if (status === "off") return "Sites appear once Chromium restarts with DevTools on"
  if (status === "error") return "Could not read sites from Chromium"
  return ""
}

// Hero copy for the focused view: the browser and what it is made of.
function focusTitle(rows) {
  if (!rows || rows.length === 0 || rows[0].type !== "header") return ""
  var pages = 0
  for (var i = 1; i < rows.length; i++) if (rows[i].type === "site") pages++
  return rows[0].name + " · " + (pages === 1 ? "1 page" : pages + " pages")
}

function focusMeta(rows, snapshot) {
  if (!rows || rows.length === 0 || rows[0].type !== "header" || !snapshot || !snapshot.mem) return ""
  var h = rows[0]
  var parts = [fmtMem(h.mem) + " · " + Math.round(share(h.mem, snapshot.mem.total) * 100) + "% of RAM"]
  var cpu = fmtCpu(h.cpu)
  if (cpu !== "") parts.push(cpu + " CPU")
  var age = fmtAge(h.age)
  if (age !== "") parts.push("alive " + age)
  return parts.join(" · ")
}

// ---- Tanks. Two vertical columns beside the rows, RAM and CPU, filled
// from the bottom with one segment per row in row order, so the heaviest
// app sits at the bottom of both and a segment's neighbour is the same app
// in the other tank. In the focused view the tank is the browser: its
// pages fill it, scaled to the browser's own total.
//
// Each segment: { key, parentKey, frac, depth, rank, start } with frac of
// the tank's full height. Whatever is left is the tank's empty top.
function tankSegments(snapshot, rows, which) {
  var out = []
  if (!snapshot || !snapshot.mem || !rows || rows.length === 0) return out
  var focused = rows[0].type === "header"
  var total
  if (focused) total = Math.max(1, Number(rows[0][which]) || 0)
  else if (which === "cpu") total = (Number(snapshot.ncpu) || 1) * 100
  else if (which === "gpu") total = 100
  else if (which === "disk") {
    // Per-process counts and the block layer disagree a little (caches,
    // buffering), so the gauge is whichever is larger; never over-full.
    var sum = 0
    for (var d = 0; d < rows.length; d++) if (rows[d].type !== "note" && rows[d].type !== "header") sum += Number(rows[d].disk) || 0
    total = Math.max(Number(snapshot.disk) || 0, sum, 1)
  }
  else total = snapshot.mem.total
  var accounted = 0
  var rank = -1
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (row.type === "note" || row.type === "header") continue
    rank++
    var v = Number(row[which]) || 0
    accounted += v
    out.push({ key: row.key, parentKey: row.parentKey, frac: share(v, total), depth: row.depth, rank: rank })
  }
  // Everything the list does not show: in the focused view the pages past
  // the cut; in the app view the tail of small apps, other users, the
  // kernel, where memory uses the machine's own number for that.
  var used
  if (focused) used = total
  else if (which === "cpu") used = Math.min(total, (Number(snapshot.load[0]) || 0) * 100)
  else if (which === "gpu") used = Math.min(100, Number(snapshot.gpu) || 0)
  else if (which === "disk") used = Number(snapshot.disk) || 0
  else used = snapshot.mem.used
  var rest = used - accounted
  if (rest > total * 0.005) out.push({ key: "rest", parentKey: "", frac: share(rest, total), depth: 0, rank: 99 })
  return stackSegments(out)
}

// ---- Morphing between two stacked layouts. Keys present on both sides
// slide; a key only on the new side grows out of its final place; a key
// only on the old side shrinks where it stood.
function lerp(a, b, t) { return a + (b - a) * t }

function morphSegments(fromMap, toList, t) {
  var out = []
  var seen = {}
  for (var i = 0; i < toList.length; i++) {
    var to = toList[i]
    var from = fromMap[to.key]
    seen[to.key] = true
    if (!from) from = { start: to.start + to.frac / 2, frac: 0, rank: to.rank }
    out.push({ key: to.key, start: lerp(from.start, to.start, t), frac: lerp(from.frac, to.frac, t), rank: to.rank, depth: to.depth })
  }
  if (t < 1) {
    for (var key in fromMap) {
      if (seen[key]) continue
      var f = fromMap[key]
      out.push({ key: key, start: lerp(f.start, f.start + f.frac / 2, t), frac: lerp(f.frac, 0, t), rank: f.rank, depth: f.depth || 0 })
    }
  }
  return out
}

function stackSegments(segments) {
  var out = []
  var cum = 0
  for (var i = 0; i < segments.length; i++) {
    var s = segments[i]
    out.push({ key: s.key, parentKey: s.parentKey, frac: s.frac, depth: s.depth, rank: s.rank, start: cum })
    cum += s.frac
  }
  return out
}

function segmentMap(segments) {
  var m = {}
  for (var i = 0; i < segments.length; i++) m[segments[i].key] = segments[i]
  return m
}

function rowMap(rows) {
  var m = {}
  for (var i = 0; i < rows.length; i++) m[rows[i].key] = rows[i]
  return m
}

function keysOf(items) {
  var out = []
  for (var i = 0; i < items.length; i++) out.push(items[i].key)
  return out
}

// Alpha ladder for segments: the biggest reads strongest, the tail fades.
function segmentAlpha(rank, depth) {
  var base = [0.85, 0.66, 0.52, 0.42, 0.34, 0.28, 0.24, 0.21, 0.19, 0.17]
  var a = rank < base.length ? base[rank] : 0.14
  return depth > 0 ? Math.max(0.2, a) : a
}

// The confirmation says exactly what will happen and what it costs, so the
// choice is made on facts rather than on a verb.
function confirmMessage(row, force) {
  if (!row) return ""
  if (row.type === "site") {
    var what = row.targets.length > 1 ? "all " + row.targets.length + " tabs of " + row.name : row.name
    return "Close " + what + "? Frees about " + fmtMem(row.mem) + ". Unsaved work in them is lost."
  }
  if (force) return "Force-kill " + row.name + "? It ignored the polite request. Anything unsaved is gone."
  return "Quit " + row.name + "? Frees about " + fmtMem(row.mem) + "."
}

function confirmVerb(row, force) {
  if (!row) return "Confirm"
  if (row.type === "site") return "Close"
  return force ? "Force" : "Quit"
}

function clampIndex(index, length) {
  if (length <= 0) return -1
  if (index < 0) return 0
  if (index >= length) return length - 1
  return index
}

function indexOfKey(rows, key) {
  for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return i
  return -1
}

// History for the sparkline: one point per 20 s, half an hour deep.
var HISTORY_STEP_MS = 20000
var HISTORY_MAX = 90

function pushHistory(history, snapshot, nowMs) {
  if (!snapshot || !snapshot.mem) return history
  var last = history.length > 0 ? history[history.length - 1] : null
  if (last && nowMs - last.t < HISTORY_STEP_MS) return history
  var next = history.slice(Math.max(0, history.length - HISTORY_MAX + 1))
  next.push({ t: nowMs, mem: usedFraction(snapshot), cpu: Math.min(1, loadFraction(snapshot)) })
  return next
}

// Trend over the last five minutes of samples, for the sparkline's caption.
function historyTrend(history) {
  if (!history || history.length < 4) return ""
  var first = history[Math.max(0, history.length - 16)].mem
  var last = history[history.length - 1].mem
  var delta = last - first
  if (delta > 0.04) return "climbing"
  if (delta < -0.04) return "falling"
  return "steady"
}

function historySpan(history) {
  if (!history || history.length < 2) return ""
  var ms = history[history.length - 1].t - history[0].t
  var min = Math.round(ms / 60000)
  return min < 1 ? "" : "last " + min + " min"
}

// ---- Colour per app. A fixed palette that sits well on a dark theme,
// picked by a hash of the row key so an app keeps its colour from sample
// to sample and from open to open.
var PALETTE = ["#f2a65a", "#7fb8e6", "#9ad48a", "#e6a0c4", "#c9a6f0", "#7fd9d0", "#f0d06a", "#f08a8a", "#a3b8f0", "#d4e08a", "#f0b7a0", "#8ad4b3", "#e0a3e6", "#a8c8ff"]

function colorFor(key) {
  var h = 0
  var s = String(key || "")
  for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return PALETTE[h % PALETTE.length]
}

// Largest value per column among the rows, for the bars under the numbers.
function columnMax(rows, which) {
  var m = 0
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].type === "note" || rows[i].type === "header") continue
    var v = Number(rows[i][which]) || 0
    if (v > m) m = v
  }
  return m
}

function railCaption(snapshot, which, rows) {
  if (!snapshot || !snapshot.mem) return ""
  // Focused on a browser, the rails are the browser's, so are the captions.
  if (rows && rows.length > 0 && rows[0].type === "header") {
    var h = rows[0]
    if (which === "mem") return fmtMem(h.mem) + " of " + fmtMem(snapshot.mem.total)
    if (which === "cpu") return Math.round(h.cpu) + "% of " + ((Number(snapshot.ncpu) || 1) * 100) + "%"
    if (which === "gpu") return Math.round(h.gpu) + "%"
    if (which === "disk") return fmtRate(h.disk)
  }
  if (which === "mem") return fmtMem(snapshot.mem.used) + " of " + fmtMem(snapshot.mem.total)
  if (which === "cpu") return Math.round(Math.min(1, loadFraction(snapshot)) * 100) + "%"
  if (which === "gpu") return Math.round(Number(snapshot.gpu) || 0) + "%"
  if (which === "disk") return fmtRate(snapshot.disk)
  if (which === "net" && snapshot.net) return "↓ " + fmtRate(snapshot.net.down) + "  ↑ " + fmtRate(snapshot.net.up)
  return ""
}

// The network rail has no per-app split, so it shows the machine's two
// directions against a 10 MB/s scale, which is where a home link tops out.
var NET_SCALE = 10 * 1024 * 1024
function netFractions(snapshot) {
  if (!snapshot || !snapshot.net) return { down: 0, up: 0 }
  return { down: Math.min(1, snapshot.net.down / NET_SCALE), up: Math.min(1, snapshot.net.up / NET_SCALE) }
}
