# GmailActions

Dopamine Rootless iOS 15+ jailbreak tweak by **tb** for **Gmail** (`com.google.Gmail`) that adds configurable background notification actions and toggleable buttons when long-pressing or expanding a mail notification from the Lock Screen, Banner, or Notification Center.

Configurable in the iOS **Settings** app under **GmailActions** via PreferenceLoader.

## Features & Available Actions

### Custom Actions
- **Mark as read** (native Gmail action ID `10`, `UNNotificationActionOptionNone`)
- **Mark as Read & Archive** (custom action ID `100`, `UNNotificationActionOptionNone`, chained sequentially in the background)
- **Mark as Read & Delete** (custom action ID `101`, `UNNotificationActionOptionDestructive`, chained sequentially in the background)

### Native Action Toggles
- **Archive** (native action ID `1`)
- **Trash (Delete)** (native action ID `3`)
- **Reply** (native action ID `6`)
- **Reply All** (native action ID `4`)

### Master Toggle
- **Enable Tweak** (`enabled`): When turned OFF, Gmail reverts to stock unmodified notification action buttons.

## Preferences & Dynamic Live Updating
- Settings are managed in the iOS Settings app via `PreferenceLoader` (`/var/jb/Library/PreferenceLoader/Preferences/GmailActions.plist`).
- Changes take effect **immediately in real time** without requiring a respring or app restart. PreferenceLoader broadcasts the `com.tb.gmailactions/settingschanged` Darwin notification, which triggers Gmail to re-evaluate enabled buttons and dynamically update its registered `UNNotificationCategory` set with iOS's `UNUserNotificationCenter`.

## Action Ordering
When all options are enabled, actions are arranged in the following priority order:
1. **Mark as read** (`10`)
2. **Mark as Read & Archive** (`100`)
3. **Mark as Read & Delete** (`101`, destructive styling)
4. **Archive** (`1`) or **Trash** (`3`)
5. **Reply all** (`4`) if present, then **Reply** (`6`)

Disabling any toggle in Settings cleanly removes that specific button from the notification menu without affecting the remaining actions.

## Project Structure
- [`Makefile`](Makefile) — Rootless Theos build configuration (`arm64` + `arm64e`, iOS `15.0+` target)
- [`control`](control) — Debian package metadata (`com.tb.gmailactions`, version 1.1.1, author `tb`)
- [`GmailActions.plist`](GmailActions.plist) — Substrate filter targeting `com.google.Gmail`
- [`Tweak.x`](Tweak.x) — Logos hooks for `GBTNotificationActionHelperServiceImpl`, `HUBUserNotificationsServiceImpl`, and `GBTNotificationActionController` with dynamic preference loading
- `layout/Library/PreferenceLoader/Preferences/GmailActions.plist` — PreferenceLoader specifiers definition
- `layout/Library/PreferenceLoader/Preferences/GmailActions.png` — Settings icon (29x29, 58x58 `@2x`, 87x87 `@3x`)

## Build & Package
```bash
export THEOS=/home/cytubeadmin/theos
rm -rf /tmp/GmailActions_build
cp -r "/mnt/c/Users/tb/Documents/Jailbreak tweaks/GmailActions" /tmp/GmailActions_build
cd /tmp/GmailActions_build
make clean package FINALPACKAGE=1
```
