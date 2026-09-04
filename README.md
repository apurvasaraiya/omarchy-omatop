# omatop

Who is eating the laptop. A bar widget for the [Omarchy](https://omarchy.org/)
shell that answers one question when you click it: which app, and inside
Chromium which site, is holding the memory and burning the CPU right now,
with a way to close it from the same row.

`htop` shows twenty-three rows called `chromium`. This shows one row called
Chromium that opens into `cursor.com 1.7 GB`, `wikipedia.org 42 MB`,
`Extensions 200 MB`, `Browser core 970 MB`.

## What you see

- **Bar:** the icon is a small tank. Its fill is the share of RAM in use,
  from a cheap sample every twenty seconds. Calm machines draw it quietly,
  busy ones (RAM over 75% or load over half the cores) at full strength, and
  when the CPU is saturated or memory is nearly gone it takes the bar's
  active colour and breathes slowly. A click squashes it and the liquid
  settles back. Hover shows "CPU 45% · RAM 9.5 GB" and nothing else. Middle
  click posts that as a notification. Right click opens btop.
- **Panel (left click):** one sentence up top, for example
  "Chromium holds 3.4 GB, mostly cursor.com", or when memory is tight,
  "Tight. Closing cursor.com frees 1.7 GB", with the totals under it: RAM,
  CPU, GPU and the network rate. Under that a sparkline of RAM for the last
  half hour with CPU dotted behind it and a one-word trend. Then three
  tanks, RAM, CPU and GPU, beside the ten heaviest apps, each with its icon
  and its CPU, RAM, GPU and NET figures. Each tank segment is a row, in row
  order in all three, so the same app sits at the same height in each.
  Hover a segment or a row and the tanks dim to that one segment, lit in
  the accent, with a band drawn tank to tank and into the row. The tanks
  are painted on a canvas that morphs from one sample to the next, so a
  change in size or order flows rather than snaps. There is no "and n
  more"; what does not make the top ten is not what is slowing the machine.
- **Sort and search.** Click a column title, or press `s`, to sort by CPU,
  RAM, GPU, NET or name; the choice is saved to shell.json. Press `/` and
  type to filter rows by name or title; Enter keeps the filter, Esc drops
  it.
- **Enter or a click** on an app brings its window to the front (btop if it
  has none). On a browser it drills into a view of only that browser's
  pages.
- **The browser view** lists every page the browser holds, with its
  favicon straight out of Chromium's own cache, and one row for the browser
  itself (extensions, GPU, network, background pages). The tanks become the
  browser: its pages fill them, scaled to the browser's own total. Enter or
  a click on a page brings that tab, or web-app window, to the front. `h`,
  Esc or the header row go back. A page row is one origin across all its
  tabs and windows. Pages Omarchy installed as web apps are named after the
  app, carry its icon and are tagged "Omarchy app", so YouTube, WhatsApp and
  friends read apart from whatever else you have open.
- **Closing:** the × on the row under the cursor, or the `x` key. One
  confirmation, which names what closes and roughly what it frees. Sites are
  closed through DevTools, so the tab goes away cleanly. Apps get SIGTERM;
  if one is still there five seconds later the row says so and a second `x`
  offers a force kill. The shell, Hyprland and the session plumbing are
  listed but never offered.

Keys: `j` `k` move, `Enter` go, `l` into a browser, `h` back out, `x` close,
`r` resample, `b` btop, `Esc` back or dismiss.

## How it knows which site is which

Chromium does not put the site in a renderer's command line. The only clean
source is the DevTools protocol: attaching to a page and starting a
zero-length trace returns a `TracingStartedInBrowser` event that lists the
page's frames with their OS process ids. That takes about 50 ms per page,
is cached per tab, and is redone only when a tab navigates or its renderer
goes away.

For that to work Chromium has to expose DevTools locally. `install.sh`
appends this to `~/.config/chromium-flags.conf`:

```
--remote-debugging-port=0
```

Port zero means Chromium picks a random port and writes it to
`~/.config/chromium/DevToolsActivePort`, which the collector reads. It is
bound to 127.0.0.1. Any process running as you can already read your
profile directory, so this does not widen what a local process could do;
it is still a debugging endpoint, so remove the line if that trade is not
for you. Without it the panel still works, at app level, and the browser
row says that sites appear after a restart.

Memory is PSS from `smaps_rollup` for the heaviest 32 processes and RSS for
the rest, so Chromium's shared pages are counted once. CPU is the classic
per-core percent from `/proc/<pid>/stat` deltas, summed per app.

GPU comes from the DRM driver's per-client counters in `/proc/<pid>/fdinfo`
(the i915 `drm-engine-*` busy times), so it is per process without root,
for the sixty heaviest processes. The GPU tank's total is one full engine.

Network is the one thing the kernel will not give an unprivileged reader
per process: byte counts per socket need root or eBPF. So the NET column is
the number of open sockets per app, which still points at who is talking,
and the hero shows the machine's own receive and send rate.

## Install

```
git clone <this repo> ~/dev/omarchy/omatop
~/dev/omarchy/omatop/install.sh
```

The script symlinks the plugin into `~/.config/omarchy/plugins/apurva.omatop`,
adds the Chromium flag if it is missing, and enables the widget on the right
side of the bar. Restart Chromium once for site rows.

Settings, in the widget's entry in `~/.config/omarchy/shell.json`:

- `maxApps` (default 10): how many apps the panel lists.
- `card` is set to `false` on install, so the widget sits in the bar without
  the per-widget card outline of the V7 bar clone.

## Files

- `omatop` - the collector and the actions. Python 3, standard library only.
  `omatop watch --interval 2` streams one JSON snapshot per line;
  `omatop close-site` and `omatop kill` are what the confirmation runs.
- `BarWidget.qml` - the bar glyph and the panel's host.
- `Panel.qml` - the breakdown.
- `Model.js` - formatting, the hero sentence, row flattening. No QML in it.

Built against omarchy `4.0.0.r2014` (September 2026).
