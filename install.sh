#!/bin/bash
# Development install: link this checkout into the shell so edits land live.
# Regular users should use `omarchy plugin add` instead (see README).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugins=~/.config/omarchy/plugins

mkdir -p "$plugins"
ln -sfn "$here" "$plugins/apurva.omatop"
echo "linked $plugins/apurva.omatop -> $here"

sleep 1
if omarchy plugin list 2>/dev/null | grep -q 'apurva.omatop.*enabled'; then
  echo "widget already in the bar"
else
  omarchy plugin enable apurva.omatop right
fi

# Chromium's local DevTools endpoint, for the page view. Idempotent.
python3 "$here/omatop" setup
