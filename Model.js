.pragma library

// Pure helpers for the Omatop panel: formatting, the hero sentence, and the
// flattening of a snapshot into the rows the panel paints. Nothing in here
// touches QML objects, so it can be reasoned about (and tested) on its own.

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

function share(kb, totalKb) {
  var t = Number(totalKb) || 0
  if (t <= 0) return 0
  return Math.max(0, Math.min(1, (Number(kb) || 0) / t))
}

function usedFraction(snapshot) {
  if (!snapshot || !snapshot.mem) return 0
  return share(snapshot.mem.used, snapshot.mem.total)
}

// Under this much headroom the kernel starts reclaiming aggressively and
// the laptop feels it: that is the line between "busy" and "tight".
var TIGHT_FRACTION = 0.12

function isTight(snapshot) {
  if (!snapshot || !snapshot.mem || !snapshot.mem.total) return false
  return snapshot.mem.available / snapshot.mem.total < TIGHT_FRACTION
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

// The one sentence the panel opens with. It names the culprit when there is
// one, and says so when there is not, so the reader never has to scan.
function heroTitle(snapshot) {
  var top = topApp(snapshot)
  if (!snapshot || snapshot.light || !top) return "Reading…"
  var used = snapshot.mem.used
  var s = share(top.mem, used)
  if (s >= 0.3) {
    var line = top.name + " holds " + fmtMem(top.mem)
    var site = topSite(top)
    if (site && share(site.mem, top.mem) >= 0.35) line += ", mostly " + (site.omarchy ? site.app : site.name)
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

function barTooltip(snapshot) {
  if (!snapshot || !snapshot.mem) return "Memory"
  var line = fmtMem(snapshot.mem.used) + " of " + fmtMem(snapshot.mem.total) + " in use"
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
      name: app.name,
      subtitle: app.title || (app.count > 1 ? app.count + " processes" : ""),
      mem: app.mem,
      cpu: app.cpu,
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
      name: page.omarchy ? page.app : page.name,
      subtitle: siteSubtitle(page),
      mem: page.mem,
      cpu: page.cpu,
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
      name: app.name + " itself",
      subtitle: "extensions, GPU, network, background pages",
      mem: selfMem,
      cpu: Math.round(selfCpu * 10) / 10,
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
      name: devtoolsNote(app.devtools),
      subtitle: "", mem: 0, cpu: 0, pids: [], root: 0, protectedRow: true,
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

// The bar's three states, from the cheap sample: calm, working, hot.
// "Hot" is either memory nearly gone or every core busy; the glyph swaps to
// the CPU when it is the processor that is saturated and memory is fine.
function loadFraction(snapshot) {
  if (!snapshot || !snapshot.load || !snapshot.ncpu) return 0
  return (Number(snapshot.load[0]) || 0) / snapshot.ncpu
}

function barState(snapshot) {
  if (!snapshot || !snapshot.mem) return "calm"
  var cpuHot = loadFraction(snapshot) >= 0.9
  if (isTight(snapshot) || (cpuHot && usedFraction(snapshot) >= 0.8)) return "hot"
  if (cpuHot) return "cpu"
  if (usedFraction(snapshot) >= 0.75 || loadFraction(snapshot) >= 0.5) return "busy"
  return "calm"
}

function barGlyph(state) {
  return state === "cpu" ? "\u{F0EE0}" : "\u{F035B}"
}

function devtoolsNote(status) {
  if (status === "off") return "Sites appear once Chromium restarts with DevTools on"
  if (status === "error") return "Could not read sites from Chromium"
  return ""
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

function segmentAlphas(count) {
  var base = [0.85, 0.62, 0.46, 0.34, 0.25, 0.18]
  var out = []
  for (var i = 0; i < count; i++) out.push(i < base.length ? base[i] : 0.14)
  return out
}
