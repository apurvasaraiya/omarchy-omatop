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
  if (n < 0.5) return ""
  return Math.round(n) + "%"
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
  var parts = [fmtMem(m.used) + " of " + fmtMem(m.total) + " in use"]
  if (isTight(snapshot)) parts.push("only " + fmtMem(m.available) + " free")
  var load = fmtLoad(snapshot.load)
  if (load !== "") parts.push("load " + load + (snapshot.ncpu ? " on " + snapshot.ncpu + " cores" : ""))
  return parts.join(" · ")
}

// What the meta line says while a row is under the cursor: that row, in
// the same units as the totals, so hovering is reading.
function hoverMeta(row, snapshot) {
  if (!row || !snapshot || !snapshot.mem) return ""
  if (row.type === "note") return ""
  var parts = [fmtMem(row.mem) + " · " + Math.round(share(row.mem, snapshot.mem.total) * 100) + "% of RAM"]
  var cpu = fmtCpu(row.cpu)
  if (cpu !== "") parts.push(cpu + " CPU")
  var age = fmtAge(row.age)
  if (age !== "") parts.push("alive " + age)
  if (row.type === "app" && row.count > 1) parts.push(row.count + " processes")
  return parts.join(" · ")
}

function barTooltip(snapshot) {
  if (!snapshot || !snapshot.mem) return "Memory"
  var line = fmtMem(snapshot.mem.used) + " of " + fmtMem(snapshot.mem.total) + " in use"
  if (snapshot.load && snapshot.ncpu) line += " · CPU " + Math.round(Math.min(1, loadFraction(snapshot)) * 100) + "%"
  var top = topApp(snapshot)
  if (top) line += " · " + top.name + " " + fmtMem(top.mem)
  return line
}

// Rows the panel paints, top to bottom. The heaviest apps, and under an
// opened browser its heaviest pages plus one row for the browser itself.
// No "and n more": what does not make the cut is not what is slowing the
// machine.
var MAX_PAGES = 5

function buildRows(snapshot, expanded, maxApps) {
  var rows = []
  if (!snapshot || !snapshot.apps) return rows
  var apps = snapshot.apps
  var limit = Math.min(apps.length, maxApps)
  for (var i = 0; i < limit; i++) {
    var app = apps[i]
    var open = expanded[app.key] === true
    rows.push({
      type: "app",
      key: app.key,
      parentKey: "",
      name: app.name,
      subtitle: app.title || (app.count > 1 ? app.count + " processes" : ""),
      mem: app.mem,
      cpu: app.cpu,
      age: app.age || 0,
      count: app.count || 1,
      pids: app.pids,
      root: app.root,
      protectedRow: app.protected === true,
      expandable: !!(app.sites && app.sites.length > 0),
      expanded: open,
      closable: app.protected !== true,
      browser: app.browser === true,
      devtools: app.devtools || "",
      profile: app.profile || "",
      targets: [],
      omarchy: false,
      depth: 0
    })
    if (open && app.sites) appendBrowserRows(rows, app)
  }
  return rows
}

function appendBrowserRows(rows, app) {
  var pages = []
  var selfPids = []
  var selfMem = 0
  var selfCpu = 0
  for (var j = 0; j < app.sites.length; j++) {
    var site = app.sites[j]
    if (site.kind === "site") pages.push(site)
    else {
      selfPids = selfPids.concat(site.pids)
      selfMem += site.mem
      selfCpu += site.cpu
    }
  }
  for (var k = 0; k < Math.min(pages.length, MAX_PAGES); k++) {
    var page = pages[k]
    rows.push({
      type: "site",
      key: app.key + "/" + page.key,
      parentKey: app.key,
      name: siteLabel(page),
      subtitle: siteSubtitle(page),
      mem: page.mem,
      cpu: page.cpu,
      age: page.age || 0,
      count: page.pids.length,
      pids: page.pids,
      root: 0,
      protectedRow: false,
      expandable: false,
      expanded: false,
      closable: page.closable === true && page.targets.length > 0,
      browser: false,
      devtools: "",
      profile: app.profile || "",
      targets: page.targets,
      omarchy: page.omarchy === true,
      depth: 1
    })
  }
  if (selfPids.length > 0) {
    rows.push({
      type: "bucket",
      key: app.key + "/self",
      parentKey: app.key,
      name: app.name + " itself",
      subtitle: "extensions, GPU, network, background pages",
      mem: selfMem,
      cpu: Math.round(selfCpu * 10) / 10,
      age: 0,
      count: selfPids.length,
      pids: selfPids,
      root: 0, protectedRow: false, expandable: false, expanded: false,
      closable: false, browser: false, devtools: "", profile: "", targets: [],
      omarchy: false, depth: 1
    })
  }
  if (app.devtools !== "ok") {
    rows.push({
      type: "note",
      key: app.key + "/note",
      parentKey: app.key,
      name: devtoolsNote(app.devtools),
      subtitle: "", mem: 0, cpu: 0, age: 0, count: 0, pids: [], root: 0, protectedRow: true,
      expandable: false, expanded: false, closable: false, browser: false,
      devtools: "", profile: "", targets: [], omarchy: false, depth: 1
    })
  }
}

function siteSubtitle(site) {
  var parts = []
  if (site.omarchy) parts.push("Omarchy app")
  if (site.tabs > 1) parts.push(site.tabs + " tabs")
  else if (site.omarchy) parts.push(site.name)
  else if (site.title) parts.push(site.title)
  return parts.join(" · ")
}

function devtoolsNote(status) {
  if (status === "off") return "Sites appear once Chromium restarts with DevTools on"
  if (status === "error") return "Could not read sites from Chromium"
  return ""
}

// ---- Tanks. Two vertical columns beside the rows, RAM and CPU, filled
// from the bottom with one segment per row in row order, so the heaviest
// app sits at the bottom of both and a segment's neighbour is the same app
// in the other tank. An opened browser splits its segment into its pages.
//
// Each segment: { key, parentKey, frac, depth, rank } with frac of the
// tank's full height and rank the app's position for the alpha ladder.
// Whatever is left is the tank's empty top.
function tankSegments(snapshot, rows, which) {
  var out = []
  if (!snapshot || !snapshot.mem || !rows) return out
  var total = which === "cpu" ? (Number(snapshot.ncpu) || 1) * 100 : snapshot.mem.total
  var accounted = 0
  var rank = -1
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (row.type === "note") continue
    if (row.type === "app") {
      rank++
      accounted += which === "cpu" ? row.cpu : row.mem
      if (row.expanded) {
        // The children carry it, then the app's remainder closes the gap.
        var covered = 0
        for (var k = i + 1; k < rows.length && rows[k].parentKey === row.key; k++) {
          if (rows[k].type === "note") continue
          var v = which === "cpu" ? rows[k].cpu : rows[k].mem
          covered += v
          out.push({ key: rows[k].key, parentKey: row.key, frac: share(v, total), depth: 1, rank: rank })
        }
        var appValue = which === "cpu" ? row.cpu : row.mem
        if (appValue - covered > 0)
          out.push({ key: row.key + "/rest", parentKey: row.key, frac: share(appValue - covered, total), depth: 1, rank: rank })
        continue
      }
      out.push({ key: row.key, parentKey: "", frac: share(which === "cpu" ? row.cpu : row.mem, total), depth: 0, rank: rank })
    }
  }
  // Everything the list does not show: the tail of small apps, other users,
  // the kernel. Memory uses the machine's own number for that.
  var used = which === "cpu" ? Math.min(total, (Number(snapshot.load[0]) || 0) * 100) : snapshot.mem.used
  var rest = used - accounted
  if (rest > total * 0.005) out.push({ key: "rest", parentKey: "", frac: share(rest, total), depth: 0, rank: 99 })
  return out
}

function segmentHot(segment, cursorKey) {
  if (!segment || cursorKey === "") return false
  return segment.key === cursorKey || segment.parentKey === cursorKey
}

// Alpha ladder for segments: the biggest reads darkest, the tail fades.
function segmentAlpha(rank, depth) {
  var base = [0.85, 0.66, 0.52, 0.42, 0.34, 0.28, 0.24, 0.21, 0.19, 0.17]
  var a = rank < base.length ? base[rank] : 0.14
  return depth > 0 ? a * 0.8 : a
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

// Segments with their cumulative start, bottom-up, for painting a tank.
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
