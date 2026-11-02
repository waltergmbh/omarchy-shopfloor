# Omarchy Shopfloor

Set up [Omarchy](https://omarchy.org) for the shop floor: production machines
used by standard users who have no admin rights. Omarchy assumes a single admin;
this adds the missing pieces:

- accounts outside `wheel`, so neither `sudo` nor polkit admin rights apply
- Omarchy migrations that keep working for those users at login
- theme switching without a prompt for the admin password
- an Omarchy menu without the entries a standard user cannot run
- a login screen with user switching
- one password per user for login and for unlocking the disk at boot

Developed on Omarchy 4.0.4. This is an unofficial project, not affiliated with
Omarchy.

> [!WARNING]
> These scripts change the LUKS header of your system partition, `sudoers`, the
> boot menu configuration and the login screen. Back up your LUKS header and
> keep the admin's disk passphrase. See [test status](#test-status): the
> disk password has not been verified with a reboot yet.

## Install

Requirements: Omarchy with an encrypted system partition (LUKS2) and SDDM autologin
(`/etc/sddm.conf.d/autologin.conf`), and you are logged in as the admin (group
`wheel`).

```bash
git clone https://github.com/waltergmbh/omarchy-shopfloor.git
cd omarchy-shopfloor
sudo ./add-standard-user.sh <name>
```

The script asks twice for the user's new password, then for an existing disk
passphrase, e.g. the admin's. Reboot; after the disk passphrase the user is
logged in.

Run the same command again for a user who already exists, to apply changes to
these scripts or to change their password. It resets the password: the old one
no longer works for login or disk. The script refuses admins (group `wheel`).

> [!IMPORTANT]
> SDDM logs in **the user you added last**, whichever password unlocked the
> disk. With several users, or when the admin reboots, that user's session opens
> without a login prompt. To change this, edit `User=` in
> `/etc/sddm.conf.d/autologin.conf`, or empty it to always get the login screen.

## Files

| File | Purpose |
|---|---|
| `add-standard-user.sh` | Creates or refreshes the user and sets up everything below |
| `omarchy-migrate-standard` | Runs Omarchy migrations at login, without the root parts |
| `omarchy-standard-menu` | Hides the menu entries that need root at login |
| `install-login-theme.sh` | Installs the login screen with user switching |
| `set-password.sh` | Part of `add-standard-user.sh`: one password for login and disk, locks the boot menu editor |
| `sddm-theme/Main.qml` | The modified login screen |

## What changes on the system

`add-standard-user.sh <name>`:

| Path | Content |
|---|---|
| User account `<name>` | no supplementary groups, so not in `wheel` |
| `/usr/local/bin/omarchy-migrate-standard` | copy from this repository |
| `/usr/local/bin/omarchy-standard-menu` | copy from this repository |
| `/etc/sudoers.d/omarchy-theme-browser-<name>` | one passwordless rule, see below |
| `~<name>/.config/hypr/autostart.lua` | starts both scripts at every login |
| `~<name>/.config/omarchy/extensions/omarchy-menu.jsonc` | the hidden menu entries |
| `/etc/sddm.conf.d/autologin.conf` | autologin switched to `<name>` |
| LUKS header of the system partition | one key slot and one `omarchy-user` token |
| `/boot/limine.conf` | `editor_enabled: no` |

`install-login-theme.sh`:

| Path | Content |
|---|---|
| `/usr/share/sddm/themes/omarchy-users` | copy of the Omarchy theme with its own `Main.qml` |
| `/etc/sddm.conf.d/zz-user-select.conf` | selects that theme |

The stock Omarchy theme stays untouched. Nothing under `/usr/share/omarchy` is
changed.

## How it works

### Account without admin rights

The user only gets their own primary group. At the end the script checks with
`sudo -l -U <name>` that nothing but the rule below is granted, and exits with a
warning otherwise.

### Migrations at login

Omarchy's migration runner stops at the first migration that needs `sudo`.
`omarchy-migrate-standard` runs the pending migrations itself and replaces
`sudo`, `pkexec` and `run0` with stubs that do nothing. The admin's
`omarchy update` has already done the system-wide part; only the part in the
user's home takes effect here.

A migration that still fails is logged and marked as done, so it cannot block
the others. Log: `~/.local/state/omarchy/migrate-standard.log`

### Theme switching without a password prompt

Switching the theme writes its color into the system-wide browser policy
(`/etc/chromium/policies/managed/color.json`, likewise for Chrome, Edge and
Brave). Omarchy's passwordless sudo rule for that covers only the admin, so a
standard user gets a prompt for the admin's password.

The fix is one rule per standard user, for exactly this command:

```
<name> ALL=(root) NOPASSWD: /usr/bin/omarchy-theme-set-browser-policy [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]
```

The command accepts only a six-digit hex color and writes to fixed paths. This
is the standard user's only sudo permission.

Side effect: the policy file is system-wide, so when one user switches theme,
the browser color changes for all users.

### Hidden menu entries

Many menu entries (installing and removing packages, updates, DNS, security
setup) need root. For a standard user they end in an error or a prompt for the
admin's password.

`omarchy-standard-menu` finds these entries automatically:

1. It reads the Omarchy menu (`/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc`).
2. For each entry it follows which `omarchy-*` scripts the action calls,
   directly or through other scripts.
3. If one of them calls `sudo`, `pkexec`, `run0`, `yay` or `paru`, the entry is
   overridden with `"when":"false"` in the user's menu file. It then no longer
   shows in the menu or in search.

Entries without a root step stay visible, also under Install, Remove, Setup and
Update (web apps, monitors, keybindings, default browser). A submenu disappears
once all its entries are hidden.

Update → Password → User is hidden as well, even though it needs no root: it only
changes the login password, which would then drift from the disk passphrase.

To see the current list and the reason for each entry:

```bash
omarchy-standard-menu --list
```

The script runs at every login, so the list follows Omarchy updates. It rewrites
the user's menu file completely; a hand-maintained file is saved once as
`omarchy-menu.jsonc.bak`.

To adjust it, edit these in the script:

- `KEEP`: menu ids that stay visible despite a match.
- `HIDE`: menu ids that are hidden although they need no root.
- `ALLOWED`: privileged helpers the user may run through a sudo rule (currently
  only `omarchy-theme-set-browser-policy`).

Limits:

- The analysis is static and rather too strict. Setup → Default → Agent is
  hidden, for example, because selecting a missing agent would install it.
- Hiding is convenience, not a security boundary. Users can edit their menu
  file; they still lack the rights.

### Login screen with user switching

The stock Omarchy SDDM theme only shows a password field for the user who logged
in last. `install-login-theme.sh` installs a copy as the theme `omarchy-users`,
where Up/Down or Tab switches the user. Logo and background color come from the
stock theme.

To use your own logo, run this as the admin, without `sudo` (`omarchy-plymouth-set`
asks for the password itself):

```bash
omarchy-plymouth-set "#1a1b26" "#ffffff" /path/to/logo.png
sudo ./install-login-theme.sh
```

The arguments are the background color, the color of the lock and password field,
and the logo, a PNG file that must not be a symlink. Use a logo that is readable
on the background color. This also changes the boot screen and rebuilds the
initramfs, so it can take a while; the new logo shows after the next reboot.
`install-login-theme.sh` is needed because the login screen is a copy of the stock
theme. The color of the user name is fixed in `sddm-theme/Main.qml` and does not
follow these arguments.

To get the Omarchy logo back:

```bash
omarchy-refresh-plymouth
omarchy-refresh-sddm
sudo ./install-login-theme.sh
```

Back to the stock theme: `sudo ./install-login-theme.sh --remove`

### One password for login and disk

The boot prompt is not a user login but the unlocking of the LUKS-encrypted
system partition, and the Omarchy installer sets its passphrase to the admin's
password. A standard user would need the admin's password to boot. With separate
passwords for login and disk, people also typed the disk password on the lock
screen, which only checks the login password.

`set-password.sh` therefore asks once for the new password and sets it in both
places: as the login password (`chpasswd`) and as an additional LUKS key slot.
The key slot needs an existing disk passphrase. If that is wrong, the script
stops before the login password changes. The admin's passphrase keeps working.

- To change it, run `add-standard-user.sh <name>` again. The new slot replaces
  the user's old one; any existing passphrase will do, not only the old one.
- An `omarchy-user` LUKS2 token records which slot belongs to which user
  (`sudo cryptsetup luksDump <partition>`, under "Tokens").
- Change it only through `add-standard-user.sh`, which takes an admin. The menu
  entry for changing the password is hidden, but `passwd` in a terminal still
  works; the boot prompt then still expects the old password and the two drift
  apart.
- The boot prompt uses the initramfs keyboard layout. Test passwords with
  non-ASCII characters or layout-dependent keys (such as y/z) with a reboot while
  the admin's passphrase is still there as a fallback.

Boot menu editor: anyone who knows a disk passphrase could press `e` in the boot
menu, change the kernel parameters (e.g. `init=/bin/bash`) and get a root shell
after unlocking. That would defeat the separation between admin and standard
user. Limine leaves the editor enabled unless `limine.conf` says otherwise, so
the script puts `editor_enabled: no` at the top of `/boot/limine.conf` (path from
`ESP_PATH` in `/etc/default/limine`).

- `limine-update` and kernel updates keep this line; they only change the boot
  entries.
- `omarchy-refresh-limine` and the factory reset rewrite the file from the
  Omarchy template; run `add-standard-user.sh` again afterwards.
- To check: `sudo grep -n editor_enabled /boot/limine.conf`
- Not covered: booting from a USB stick. Only a UEFI password and disabled USB
  boot in the device's UEFI setup protect against that.

## Known limitations

These functions live outside the menu, so standard users can still reach them.
They fail or ask for the admin's password:

| Trigger | Behavior |
|---|---|
| Middle click on the clock (time zone) | `sudo timedatectl` fails |
| Network panel → DNS | prompts for the admin's password |
| Super+Shift+D (Docker) | prompts for the admin's password |
| Removing a packaged app in the launcher | `sudo pacman -Rns` fails |
| Update icon in the bar | `omarchy-update` fails |
| Super+Shift+Ctrl+A (choose agent) | fails if the agent still has to be installed |

## Verify

```bash
id <name>                # no group wheel
sudo -l -U <name>        # only the browser policy rule (and the asdcontrol denial)
```

Logged in as the standard user:

- Switching the theme runs without a password prompt.
- In the menu, entries with a root step are gone from Install, Remove, Setup and
  Update, such as Install → Package and Update → Omarchy.

## Test status

| Item | Status |
|---|---|
| Theme switching without a prompt | tested as a standard user |
| Menu generator | checked against Omarchy's menu model, not yet in the running menu as a standard user |
| `add-standard-user.sh` with the menu step, for existing users | syntax check only, not run yet |
| `set-password.sh` | one password for login and disk checked on a LUKS2 test container (file), the editor lock on a copy of the Omarchy template; **not yet verified with a reboot** |

## Uninstall

```bash
sudo userdel -r <name>
sudo rm /etc/sudoers.d/omarchy-theme-browser-<name>
sudo rm /usr/local/bin/omarchy-migrate-standard /usr/local/bin/omarchy-standard-menu
sudo ./install-login-theme.sh --remove
```

Remove only the two scripts under `/usr/local/bin` if no other standard user has
them in their autostart. Put the desired user back into
`/etc/sddm.conf.d/autologin.conf`.

To remove the user's disk passphrase, read the slot number in the `omarchy-user`
token from `sudo cryptsetup luksDump <partition>`, then run
`sudo cryptsetup token remove --token-id <token> <partition>` and
`sudo cryptsetup luksKillSlot <partition> <slot>` (asks for the admin's
passphrase). Never remove the last remaining slot.

## License

[MIT](LICENSE). `sddm-theme/Main.qml` is derived from Omarchy's SDDM theme,
which is also under the MIT license; see
[`sddm-theme/LICENSE.omarchy`](sddm-theme/LICENSE.omarchy).
