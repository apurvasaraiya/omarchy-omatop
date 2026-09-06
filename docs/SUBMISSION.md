# Marketplace submission draft

Post as an issue on omacom/omarchy-plugin-marketplace, using the "Submit a
plugin" form. The commit below is tag v1.0.1; re-review pins a new SHA after
any fix.

---

**Plugin:** Omatop — who is eating the laptop
**Id:** `apurva.omatop`
**Repo:** https://github.com/apurvasaraiya/omarchy-omatop
**Commit:** `52319fc810f1469a30cbb15e7e215efaef727ef9` (tag `v1.0.1`)
**Kinds:** bar-widget
**Author:** Apurva Saraiya

A bar widget that shows memory and CPU by app, and inside Chromium by
site, with a confirmed close from the row. Five vertical gauges (RAM, CPU,
GPU, disk, network) split by app in the app's colour; a search field; a
scrolling list of up to fifty apps with icons; Enter brings the app or tab
to the front; Ctrl+X quits or closes a tab behind one confirmation.

**What it runs:** one Python 3 script (standard library only), spawned by
the shell: a sampler streaming JSON every 2 s while the panel is open, a
light sample every 20 s while closed, and short one-shot actions.

**What it reads:**
- `/proc` for this user's processes: stat, statm, smaps_rollup, cmdline,
  io, fd and fdinfo (GPU counters and socket counts).
- `/proc/meminfo`, `/proc/loadavg`, `/proc/uptime`, `/proc/net/dev`,
  `/proc/diskstats`.
- `~/.local/share/applications/*.desktop` (to recognise Omarchy web apps).
- `~/.config/chromium/DevToolsActivePort` for older setups and, over
  `127.0.0.1`, the Chromium DevTools protocol, only when the user has enabled
  it.
- A read-only copy of `~/.config/chromium/Default/Favicons`.

**What it writes:**
- `$XDG_RUNTIME_DIR/omatop-<uid>/icons/`: favicon PNGs and the database
  copy (0700 dir, exclusive temp + rename, size-capped).
- `~/.config/chromium-flags.conf`: one fixed nonzero DevTools port line, only
  when the user presses Enter on the "turn on the page view" row or runs
  `omatop setup`.
- `~/.config/omarchy/shell.json`: the sort choice, through the shell's own
  `updateEntryInline`.

**What it executes:** `hyprctl clients -j` and `hyprctl dispatch` (focus a
window), `omarchy-launch-tui btop`, `omarchy-notification-send`, `kill`
(SIGTERM, SIGKILL on a second explicit confirmation) limited to the user's
own processes.

**Network:** none beyond the loopback DevTools socket.

**Hardening:** see AGENTS.md "Release rules".
