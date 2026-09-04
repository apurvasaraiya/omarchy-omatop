#!/bin/bash
# Link the plugin into the shell, expose Chromium's DevTools locally, and
# put the widget in the bar. Safe to run again.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugins=~/.config/omarchy/plugins
flags=~/.config/chromium-flags.conf

mkdir -p "$plugins"
ln -sfn "$here" "$plugins/apurva.omatop"
echo "linked $plugins/apurva.omatop -> $here"

if ! grep -qs -- '--remote-debugging-port' "$flags"; then
  printf '%s\n' '--remote-debugging-port=0' >> "$flags"
  echo "added --remote-debugging-port=0 to $flags (restart Chromium for site rows)"
fi

sleep 1
if omarchy plugin list 2>/dev/null | grep -q 'apurva.omatop.*enabled'; then
  echo "widget already in the bar"
else
  omarchy plugin enable apurva.omatop right --before omarchy.monitor
fi

# The V7 bar clone outlines every widget unless its entry says card:false.
tmp=$(mktemp)
jq '(.bar.layout[] | select(type == "array") | .[] | select(.id == "apurva.omatop")) += {"card": false}' \
  ~/.config/omarchy/shell.json > "$tmp" && mv "$tmp" ~/.config/omarchy/shell.json
