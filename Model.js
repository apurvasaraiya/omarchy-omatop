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
    if (site && share(site.mem, top.mem) >= 0.35) line += ", mostly " + site.name
    return line
  }
  return "No single hog. " + top.name + " leads at " + fmtMem(top.mem)
}

function heroMeta(snapshot) {
  if (!snapshot || !snapshot.mem) return ""
  var m = snapshot.mem
  var parts = [fmtMem(m.used) + " of " + fmtMem(m.total) + " in use"]
  if (isTight(snapshot)) parts.push("only " + fmtMem(m.available) + " free")
  var load = fmtLoad(snapshot.load)
  if (load !== "") parts.push("load " + load)
  return parts.join(" · ")
}

function barTooltip(snapshot) {
  if (!snapshot || !snapshot.mem) return "Memory"
  var line = fmtMem(snapshot.mem.used) + " of " + fmtMem(snapshot.mem.total) + " in use"
  var top = topApp(snapshot)
  if (top) line += " · " + top.name + " " + fmtMem(top.mem)
  return line
}

// Rows the panel paints, top to bottom. Apps first by memory, sites nested
// under an expanded browser, and one summary row standing in for the tail.
function buildRows(snapshot, expanded, showAll, maxApps) {
  var rows = []
  if (!snapshot || !snapshot.apps) return rows
  var apps = snapshot.apps
  var limit = showAll ? apps.length : Math.min(apps.length, maxApps)
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
      depth: 0
    })
    if (open && app.sites) {
      for (var j = 0; j < app.sites.length; j++) {
        var site = app.sites[j]
        rows.push({
          type: site.kind,
          key: app.key + "/" + site.key,
          name: site.name,
          subtitle: siteSubtitle(site),
          mem: site.mem,
          cpu: site.cpu,
          pids: site.pids,
          root: 0,
          protectedRow: false,
          expandable: false,
          expanded: false,
          closable: site.closable === true && site.targets.length > 0,
          browser: false,
          devtools: "",
          profile: app.profile || "",
          targets: site.targets,
          depth: 1
        })
      }
      if (app.devtools !== "ok") {
        rows.push({
          type: "note",
          key: app.key + "/note",
          name: devtoolsNote(app.devtools),
          subtitle: "", mem: 0, cpu: 0, pids: [], root: 0, protectedRow: true,
          expandable: false, expanded: false, closable: false, browser: false,
          devtools: "", profile: "", targets: [], depth: 1
        })
      }
    }
  }
  if (!showAll && apps.length > limit) {
    var rest = 0
    for (var k = limit; k < apps.length; k++) rest += apps[k].mem
    rows.push({
      type: "more",
      key: "more",
      name: (apps.length - limit) + " more",
      subtitle: "press m",
      mem: rest, cpu: 0, pids: [], root: 0, protectedRow: true,
      expandable: false, expanded: false, closable: false, browser: false,
      devtools: "", profile: "", targets: [], depth: 0
    })
  }
  return rows
}

function siteSubtitle(site) {
  if (site.kind === "site") {
    if (site.tabs > 1) return site.tabs + " tabs"
    return site.title || ""
  }
  return site.title || ""
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
