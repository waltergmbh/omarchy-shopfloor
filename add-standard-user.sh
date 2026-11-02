#!/usr/bin/env bash
# Create a standard (non-sudo) Omarchy user.
#
# Omarchy seeds the desktop config from /etc/skel and finishes the per-user
# setup on first login (omarchy-provision-first-run), so all that is needed
# here is an account that is NOT in the wheel group. The user is also logged in
# automatically at boot and gets one password for login and the encrypted disk.
# For a standard user that already exists the setup is applied again.
#
# Usage: sudo ./add-standard-user.sh <username>

set -euo pipefail

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \?//'
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  usage
  exit 0
fi
if (( $# != 1 )); then
  usage >&2
  exit 1
fi
name=$1

if (( EUID != 0 )); then
  echo "Error: run with sudo." >&2
  exit 1
fi
if [[ ! $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Error: missing or invalid username." >&2
  usage >&2
  exit 1
fi
if id "$name" &>/dev/null; then
  if id -nG "$name" | grep -qw wheel; then
    echo "Error: '$name' is an admin (wheel), not a standard user." >&2
    exit 1
  fi
  echo "User '$name' exists, applying the setup again."
else
  # No -G: the user only gets their own primary group, so neither sudo (wheel)
  # nor polkit admin rights (also wheel) apply.
  useradd --create-home --shell /bin/bash "$name"
fi

home=$(getent passwd "$name" | cut -d: -f6)
autostart="$home/.config/hypr/autostart.lua"
here=$(dirname "$(readlink -f "$0")")

launch_on_start() {
  grep -qF "$1" "$autostart" || echo "o.launch_on_start(\"$1\")" >>"$autostart"
}

# Omarchy's own migration runner stops at the first migration that needs sudo,
# so standard users get a login-time runner that skips the root-only parts.
install -m 755 "$here/omarchy-migrate-standard" /usr/local/bin/omarchy-migrate-standard
launch_on_start /usr/local/bin/omarchy-migrate-standard

# Menu entries that need root only lead to errors or a prompt for the admin
# password, so they are hidden. The list is rebuilt at every login to follow
# Omarchy updates, and once right now so the first session already has it.
install -m 755 "$here/omarchy-standard-menu" /usr/local/bin/omarchy-standard-menu
launch_on_start /usr/local/bin/omarchy-standard-menu
runuser -u "$name" -- env HOME="$home" /usr/local/bin/omarchy-standard-menu

# Switching the theme writes its color into the system-wide browser policy via
# omarchy-theme-set-browser-policy. Omarchy's passwordless rule for that only
# covers the admin, so a standard user would get a polkit prompt for the admin
# password on every theme change. Grant exactly that one command; the helper
# accepts nothing but a six-digit hex color.
browser_rule=/etc/sudoers.d/omarchy-theme-browser-$name
hex='[0-9a-f]'
echo "$name ALL=(root) NOPASSWD: /usr/bin/omarchy-theme-set-browser-policy $hex$hex$hex$hex$hex$hex" >"$browser_rule"
chmod 440 "$browser_rule"
if ! visudo -cqf "$browser_rule"; then
  rm -f "$browser_rule"
  echo "Error: generated sudoers rule is invalid, removed it again." >&2
  exit 1
fi

"$here/install-login-theme.sh"

sed -i "s/^User=.*/User=$name/" /etc/sddm.conf.d/autologin.conf
echo "SDDM autologin now set to '$name'."
"$here/set-password.sh" "$name"

echo
echo "Groups: $(id -Gn "$name")"
# Deny-only entries (e.g. the "!/usr/bin/asdcontrol" rule that applies to
# everyone) grant nothing, so only non-negated entries count as sudo rights.
granted=$(sudo -l -U "$name" | sed -n '/may run the following commands/,$p' | tail -n +2 |
  grep -vF '/usr/bin/omarchy-theme-set-browser-policy [0-9a-f]' |
  grep -vE '^[[:space:]]*\([^)]*\)[[:space:]]*([A-Z]+:[[:space:]]*)*![^,]*$' || true)
if [[ -z $granted ]]; then
  echo "OK: '$name' cannot use sudo (apart from setting the browser theme color)."
else
  echo "WARNING: sudoers grants '$name' something — check the output below:" >&2
  sudo -l -U "$name" >&2
  exit 1
fi
