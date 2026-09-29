#!/bin/bash
# omarchy:summary=Install the illuminanced bar plugin and auto-brightness daemon
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

plugin_dir="$HOME/.config/omarchy/plugins/illuminanced"
conf_dir="$HOME/.config/user-autobright"
bin_dir="$HOME/.local/bin"

mkdir -p "$plugin_dir" "$conf_dir" "$bin_dir"

install -m644 "$src/plugin/illuminanced/manifest.json" "$plugin_dir/manifest.json"
install -m644 "$src/plugin/illuminanced/Panel.qml" "$plugin_dir/Panel.qml"
install -m644 "$src/user-autobright.conf" "$conf_dir/user-autobright.conf"
install -m755 "$src/user-autobright.py" "$bin_dir/user-autobright.py"

# Keep an existing calibration rather than resetting it to the defaults.
if [ -f "$conf_dir/user-autobright.conf" ] && [ "$conf_dir/user-autobright.conf" != "$src/user-autobright.conf" ]; then
  echo "Kept existing $conf_dir/user-autobright.conf"
fi

echo "Installed plugin to $plugin_dir"
echo "Installed daemon to $bin_dir/user-autobright.py"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user enable --now user-autobright.service >/dev/null 2>&1 || true
  echo "user-autobright.service enabled"
fi

echo
echo "Restart the shell to load the QML: omarchy-restart-shell"
