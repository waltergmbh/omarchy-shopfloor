#!/usr/bin/env bash
# Set one password for a user's login and for unlocking the disk at boot.
#
# The Omarchy installer sets the disk passphrase to the admin's password, so
# the boot prompt asks for it even when SDDM logs in a standard user. This asks
# for a new password once and sets it as the user's login password (lock
# screen, login screen) and as an extra LUKS key slot; the admin's disk
# passphrase keeps working. Run it again to change both: the new slot replaces
# the user's old one.
#
# Part of add-standard-user.sh; run that instead, it sets up everything.
# Usage: sudo ./set-password.sh <username>

set -euo pipefail

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
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
if [[ ! $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || ! id "$name" &>/dev/null; then
  echo "Error: missing, invalid or unknown username." >&2
  usage >&2
  exit 1
fi

# / sits on a dm-crypt mapping (e.g. /dev/mapper/root[/@]); its single sysfs
# slave is the LUKS partition.
dm=$(readlink -f "$(findmnt -no SOURCE / | sed 's/\[.*//')")
dm=${dm##*/}
if [[ $(cat "/sys/block/$dm/dm/uuid" 2>/dev/null) != CRYPT-LUKS* ]]; then
  echo "Error: / is not on a LUKS device, nothing to do." >&2
  exit 1
fi
dev=/dev/$(ls "/sys/block/$dm/slaves")
cryptsetup isLuks --type luks2 "$dev" || { echo "Error: $dev is not LUKS2." >&2; exit 1; }

# LUKS has no names for key slots, so a token of our own records which slot
# belongs to which user.
meta=$(cryptsetup luksDump --dump-json-metadata "$dev")
old_token=$(jq -r --arg u "$name" '.tokens | to_entries[] | select(.value.type == "omarchy-user" and .value.user == $u) | .key' <<<"$meta" | head -n1)
old_slot=""
[[ -n $old_token ]] && old_slot=$(jq -r --arg t "$old_token" '.tokens[$t].keyslots[0] // empty' <<<"$meta")
new_slot=$(jq -r '[range(0; 32) | tostring] - (.keyslots | keys) | first // empty' <<<"$meta")
if [[ -z $new_slot ]]; then
  echo "Error: no free key slot on $dev." >&2
  exit 1
fi

echo "New password for '$name' (login and disk at boot)."
echo "The boot prompt uses the console keymap: test umlauts or y/z with a reboot."
while true; do
  read -rsp "New password: " password; echo
  read -rsp "Retype new password: " again; echo
  if [[ -z $password ]]; then
    echo "Empty password, try again." >&2
  elif [[ $password != "$again" ]]; then
    echo "Passwords do not match, try again." >&2
  else
    break
  fi
done
unset again

# The disk first: it needs an existing passphrase and is the step that fails
# on a typo, before the login password has been touched. The new key goes in
# as a key file without a trailing newline, which is what the boot prompt
# hands over.
echo "Disk ($dev, key slot $new_slot): enter an existing disk passphrase (e.g. the admin's)."
cryptsetup luksAddKey --new-key-slot "$new_slot" "$dev" <(printf '%s' "$password")

# Killing a slot leaves its token behind with an empty slot list, so drop the
# token first. -q skips asking for a remaining passphrase; one was just given.
if [[ -n $old_token ]]; then
  cryptsetup token remove --token-id "$old_token" "$dev"
  if [[ -n $old_slot ]]; then
    cryptsetup luksKillSlot -q "$dev" "$old_slot" </dev/null 2> >(grep -v '^Nothing to read on input' >&2)
    echo "Replaced the previous disk passphrase of '$name' (key slot $old_slot)."
  fi
fi
printf '{"type":"omarchy-user","keyslots":["%s"],"user":"%s"}' "$new_slot" "$name" |
  cryptsetup token import "$dev"

printf '%s:%s\n' "$name" "$password" | chpasswd
unset password

echo "Done: '$name' logs in and unlocks the disk with the new password; other disk passphrases are unchanged."

# Knowing the disk passphrase, a user could edit the kernel command line in the
# boot menu (e.g. init=/bin/bash) and get a root shell, so the Limine editor is
# turned off. limine-update keeps the global options at the top of limine.conf;
# omarchy-refresh-limine starts over from the template, so rerun after that.
esp=$(sed -n 's/^ESP_PATH="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/default/limine 2>/dev/null | tail -n1)
limine_conf=${esp:-/boot}/limine.conf
if [[ ! -f $limine_conf ]]; then
  echo "Warning: $limine_conf not found, the boot menu editor stays enabled." >&2
elif grep -qE '^[[:space:]]*editor_enabled:[[:space:]]*no[[:space:]]*$' "$limine_conf"; then
  echo "Boot menu editor: already disabled."
else
  # Global options must come before the first entry, so put it in front of the
  # first option line.
  sed -i -E '/^[[:space:]]*editor_enabled:/d' "$limine_conf"
  sed -i -E '0,/^[a-z_]+:/s//editor_enabled: no\n&/' "$limine_conf"
  if ! grep -qx 'editor_enabled: no' "$limine_conf"; then
    echo "Warning: could not disable the boot menu editor in $limine_conf." >&2
  else
    echo "Boot menu editor: disabled in $limine_conf."
  fi
fi
