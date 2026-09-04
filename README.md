# omatop

Who is eating the laptop. A bar widget for the [Omarchy](https://omarchy.org/)
shell that answers one question when you click it: which app, and inside
Chromium which site, is holding the memory and burning the CPU right now,
with a way to close it from the same row.

`htop` shows twenty-three rows called `chromium`. This shows one row called
Chromium that opens into `cursor.com 1.7 GB`, `wikipedia.org 42 MB`,
`Extensions 200 MB`, `Browser core 970 MB`.

## What you see

- **Bar:** a memory glyph with a one-pixel mark under it. The mark's fill is
  the share of RAM in use; it thickens and takes the urgent colour when less
  than 12% is free. Hover reads the numbers. Middle click posts them as a
  notification. Right click opens btop.
- **Panel (left click):** one sentence up top, for example
  "Chromium holds 3.4 GB, mostly cursor.com", the totals beneath it, and a
  stacked bar of the biggest apps so the shares can be compared without
  reading. Then one row per app, heaviest first: name, window title or
  process count, CPU, memory. Each row's own share is painted faintly behind
  it.
- **Browser rows** open into sites. A site row is one origin across all its
  tabs and windows, including the web apps Omarchy launches as `--app`
  windows. Three buckets catch what is not a page: Extensions, Background
  pages (prerender, service workers, tabs mid-close) and Browser core (UI,
  GPU, network).
- **Closing:** the × on the row under the cursor, or the `x` key. One
  confirmation, which names what closes and roughly what it frees. Sites are
  closed through DevTools, so the tab goes away cleanly. Apps get SIGTERM;
  if one is still there five seconds later the row says so and a second `x`
  offers a force kill. The shell, Hyprland and the session plumbing are
  listed but never offered.

Keys: `j` `k` move, `Enter` or `l`/`h` open and close a browser row, `x`
close, `m` show every app, `r` resample, `b` btop, `Esc` dismiss.

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

## Install

```
git clone <this repo> ~/dev/omarchy/omatop
~/dev/omarchy/omatop/install.sh
```

The script symlinks the plugin into `~/.config/omarchy/plugins/apurva.omatop`,
adds the Chromium flag if it is missing, and enables the widget on the right
side of the bar. Restart Chromium once for site rows.

Settings, in the widget's entry in `~/.config/omarchy/shell.json`:

- `maxApps` (default 8): rows shown before the "n more" summary.

## Files

- `omatop` - the collector and the actions. Python 3, standard library only.
  `omatop watch --interval 2` streams one JSON snapshot per line;
  `omatop close-site` and `omatop kill` are what the confirmation runs.
- `BarWidget.qml` - the bar glyph and the panel's host.
- `Panel.qml` - the breakdown.
- `Model.js` - formatting, the hero sentence, row flattening. No QML in it.

Built against omarchy `4.0.0.r2014` (September 2026).
