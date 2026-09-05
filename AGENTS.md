# Agent guidance for this repo

Omarchy shell bar widget. The data comes from `omatop` (Python 3, standard
library only); the QML only paints and confirms.

## Working on it

- `omatop watch --once` prints two snapshots and exits; that is the fastest
  way to check grouping and site attribution without the shell.
- The shell's hot reload of this plugin is unreliable, and `Model.js` is a
  cached QML library. After any edit run `omarchy restart shell` before
  judging what you see.
- Synthetic pointer moves (`hyprctl dispatch movecursor`) never register as
  hover in the panel; only a real mouse does. Check state through the IPC:
  `omarchy-shell apurva.omatop state`, `... quit app:<pid>` (opens the
  confirmation on that row), `... browser`.
- Never drive the panel with synthetic keystrokes (`wtype`) unless a
  screenshot taken in the same second shows the panel open and focused;
  otherwise the keys land in whatever the user is typing into.
- Site attribution needs a Chromium started with a fixed nonzero
  `--remote-debugging-port`, normally `9222`. Port zero makes Chromium expose
  webdriver mode to pages. The collector also accepts the old port-zero
  `DevToolsActivePort` setup while it is still running.
  To test without touching the user's browser:
  `setsid -f chromium --headless=new --remote-debugging-port=9222 --user-data-dir=/tmp/x --no-first-run https://example.com`
  (`setsid` so it groups as its own app rather than under your terminal).
  Kill it when done.
- This Omarchy's Hyprland takes the Lua dispatcher form:
  `hyprctl dispatch 'hl.dsp.focus({ window = "address:0x…" })'`. The
  classic `focuswindow address:…` is rejected. The collector tries Lua first.

## Release rules (marketplace review)

Threat model: another process running as the same user plants files at
predictable paths. So:

- Every read of a path outside `/proc` goes through `read()` with
  `O_NOFOLLOW | O_NONBLOCK` and a byte cap.
- Writes create an exclusive temp under an unguessable name
  (`O_CREAT | O_EXCL | O_NOFOLLOW`) and rename onto the final name; the
  final name is only ever a rename target.
- The runtime directory is created 0700 and verified with `lstat` to be a
  directory we own, not a symlink, not group/world writable, before use.
- The favicon database copy is size-capped and copied fd to fd without
  following symlinks.
- `kill` refuses pids that are not ours, plus self, parent and pid 1.
- `omarchy plugin validate .` must pass. Commits use the GitHub noreply
  author (repo-local git config). Re-review pins a commit SHA; after a fix,
  comment the new SHA on the submission issue.
