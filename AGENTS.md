# Agent guidance for this repo

Omarchy shell bar widget. The data comes from `omatop` (Python, stdlib
only); the QML only paints and confirms.

- `omatop watch --once` prints two snapshots and exits; that is the fastest
  way to check grouping and site attribution without the shell.
- Site attribution needs a Chromium started with `--remote-debugging-port=0`.
  To test without touching the user's browser:
  `setsid -f chromium --headless=new --remote-debugging-port=0 --user-data-dir=/tmp/x --no-first-run https://example.com`
  (`setsid` so it groups as its own app rather than under your terminal).
  Kill it when done.
- Never drive the panel with synthetic keystrokes (`wtype`) unless you have
  just confirmed the panel is open and focused in a screenshot; otherwise the
  keys land in whatever the user is typing into.
- `omarchy plugin validate .` must pass. Saving any file here hot-reloads
  the plugin; shell warnings show in `journalctl --user`.
- Commits use the GitHub noreply author (repo-local git config).
