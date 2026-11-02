#!/usr/bin/env bash
# Install a copy of the Omarchy login theme that can switch users.
#
# The stock Omarchy SDDM theme only offers a password field for the user who
# logged in last. This installs it as a separate theme (omarchy-users) so the
# packaged one stays untouched and survives Omarchy updates unchanged.
#
# Usage: sudo ./install-login-theme.sh            install / update
#        sudo ./install-login-theme.sh --remove   back to the stock theme

set -euo pipefail

stock=/usr/share/sddm/themes/omarchy
theme=/usr/share/sddm/themes/omarchy-users
# Sorts after 10-theme.conf and 99-omarchy-login.conf, which both select the stock theme.
conf=/etc/sddm.conf.d/zz-user-select.conf
src="$(dirname "$(readlink -f "$0")")/sddm-theme/Main.qml"

if (( EUID != 0 )); then
  echo "Error: run with sudo." >&2
  exit 1
fi

if [[ ${1:-} == --remove ]]; then
  rm -rf "$theme" "$conf"
  echo "Removed; SDDM uses the stock Omarchy theme again."
  exit 0
fi

# Logo and images come from the stock theme, so a customized login logo carries over.
rm -rf "$theme"
cp -r "$stock" "$theme"
install -m 644 "$src" "$theme/Main.qml"

# Keep whatever background color the stock theme currently uses.
color=$(grep -m1 -oE '^  color: "#[0-9a-fA-F]+"' "$stock/Main.qml" || true)
[[ -n $color ]] && sed -i "0,/^  color: \"#[0-9a-fA-F]*\"/s//$color/" "$theme/Main.qml"

printf '[Theme]\nCurrent=omarchy-users\n' >"$conf"

echo "Installed. Log out to see it (reboot once if the old screen still shows)."
echo "On the login screen: Up/Down or Tab switches the user."
