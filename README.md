# RAID Monitor

A lightweight macOS daemon that watches Apple Software RAID arrays and sends a native notification the moment something goes wrong.

No subscriptions. No third-party RAID software. No SIP modifications. Runs silently in the background using a standard LaunchAgent.

---

## Requirements

| | |
|---|---|
| macOS | 13 Ventura or later |
| Architecture | Apple Silicon or Intel |
| Xcode Command Line Tools | Required once, to compile the notification helper |

Install the Command Line Tools if you haven't already:

```sh
xcode-select --install
```

---

## Installation

1. **Clone or download** the project and open a terminal in the project folder.

2. **(Optional) Add a custom notification icon** — place a `AppIcon.png` (1024×1024 px, square) in the project folder before running the installer. The icon appears in all notifications and in System Settings → Notifications → RAID Monitor. If omitted, a generic macOS icon is used. The installer converts the PNG to the required `.icns` format automatically.

The default icon is from by Icontoaster.com (Michael Ludwig).

3. **Run the installer:**

   ```sh
   ./install.sh
   ```

   This will:
   - Copy `raid-monitor.sh` to `~/bin/`
   - Compile and bundle the notification helper (`raid-monitor-notify.app`)
   - Install the icon into the app bundle if `AppIcon.png` is present
   - Install the config template to `~/.config/raid-monitor/config.sh`
   - Install and load the LaunchAgent

4. **Run the installation test:**

   ```sh
   ~/bin/raid-monitor.sh --test
   ```

   On first run macOS shows a one-time system prompt:

   > **"RAID Monitor" would like to send notifications**

   Click **Allow**. After that, all alerts are delivered silently — no further interaction required.

5. **Verify the agent is running:**

   ```sh
   launchctl list | grep raid-monitor
   ```

---

## Uninstallation

```sh
./install.sh --uninstall
```

This unloads the LaunchAgent and removes all installed files. You will be asked whether to also delete the logs and state directory.

---

## Configuration

The config file lives at:

```
~/.config/raid-monitor/config.sh
```

Open it in any text editor:

```sh
open -e ~/.config/raid-monitor/config.sh
```

Changes take effect on the **next poll** (within 5 minutes) — no reload needed.

### All settings

| Setting | Default | Description |
|---|---|---|
| `POLL_INTERVAL_SECONDS` | `300` | How often to check, in seconds. See note below if you change this. |
| `NOTIFY_ON_ONLINE` | `false` | Send a notification when the array returns to Online (e.g. rebuild complete). |
| `ARRAY_UUID_FILTER` | *(empty)* | Monitor only this array UUID. Leave empty to monitor all arrays. |
| `TRANSIENT_RECHECK_SECONDS` | `30` | Seconds to wait before confirming a disappeared array is truly gone. Prevents false alarms after wake from sleep on USB enclosures. |
| `SMART_ENABLED` | `false` | Run a SMART health check on each RAID member disk every poll. Requires `smartmontools` (`brew install smartmontools`). |
| `EMAIL_ENABLED` | `false` | Also send email alerts. Requires `sendmail` or `msmtp`. |
| `EMAIL_TO` | *(empty)* | Recipient address. |
| `EMAIL_FROM` | *(empty)* | Sender address (used in the `From:` header). |
| `LOG_MAX_SIZE_MB` | `5` | Log file size limit before rotation. |

### Recommended first-time setup

**1. Find your array UUID:**

```sh
diskutil appleRAID list
```

Look for the `Unique ID` line, e.g.:

```
Unique ID:   F71DAB1B-A18D-434D-B275-9A82BB3D1483
```

**2. Set the UUID filter** so the monitor tracks your specific array:

```sh
ARRAY_UUID_FILTER="F71DAB1B-A18D-434D-B275-9A82BB3D1483"
```

**3. Enable rebuild confirmation** if you want to know when a degraded array recovers:

```sh
NOTIFY_ON_ONLINE=true
```

**4. Adjust wake-from-sleep tolerance** if your USB enclosure takes more than 30 seconds to re-enumerate after the Mac wakes:

```sh
TRANSIENT_RECHECK_SECONDS=60
```

### Changing the poll interval

`POLL_INTERVAL_SECONDS` in the config must match `StartInterval` in the LaunchAgent plist. If you change it, update both and reload:

```sh
# 1. Edit ~/.config/raid-monitor/config.sh  →  POLL_INTERVAL_SECONDS=600
# 2. Edit ~/Library/LaunchAgents/com.airic-lenz.raid-monitor.plist  →  <integer>600</integer>
# 3. Reload:
launchctl unload ~/Library/LaunchAgents/com.airic-lenz.raid-monitor.plist
launchctl load   ~/Library/LaunchAgents/com.airic-lenz.raid-monitor.plist
```

### Email alerts (optional)

Set `EMAIL_ENABLED=true` and provide `EMAIL_TO`. You also need a working mail sender:

- **msmtp** (recommended): `brew install msmtp`, then configure `~/.msmtprc`
- **sendmail**: must already be configured on your system

### SMART health monitoring (optional)

SMART monitoring checks each RAID member disk for predicted drive failure on every poll.

**1. Install smartmontools:**

```sh
brew install smartmontools
```

**2. Enable in config:**

```sh
SMART_ENABLED=true
```

**What it does:**

- Runs `smartctl -H` on each member disk (e.g. `/dev/disk8` for a member listed as `disk8s2`)
- If SMART reports `FAILED` → Critical notification: "Drive Failure Predicted"
- If SMART transitions from `PASSED` to `UNKNOWN` → Warning notification
- `UNSUPPORTED` (common on some USB enclosures) → logged silently, no alert
- SMART health is persisted in the state file so alerts only fire on transitions, not on every poll

**Note on USB enclosures:** Not all USB bridges expose SMART data. If your enclosure does not support passthrough, all members will show `UNSUPPORTED` and no alerts will fire. Check with `smartctl -H /dev/diskN` before enabling.

### Updating the notification icon

To add or replace the icon after installation, drop a new `AppIcon.png` into the project directory and re-run `./install.sh`.

---

## Alerts

The monitor detects and alerts on these state changes:

| Transition | Level | Notification? |
|---|---|---|
| Any → Degraded | Warning | Yes |
| Any → Rebuilding | Info | Yes |
| Any → Failed | Critical | Yes |
| Any → Disappeared | Critical | Yes (after transient re-check) |
| Degraded/Failed → Online | Info | Only if `NOTIFY_ON_ONLINE=true` |
| SMART PASSED → FAILED | Critical | Only if `SMART_ENABLED=true` |
| SMART PASSED → UNKNOWN | Warning | Only if `SMART_ENABLED=true` |
| No change | — | No |

**Critical** alerts use macOS Time Sensitive interruption level — they break through Focus/Do Not Disturb modes.

---

## Logs

All poll events and alerts are written to:

```
~/.local/share/raid-monitor/raid-monitor.log
```

View recent activity:

```sh
tail -f ~/.local/share/raid-monitor/raid-monitor.log
```

When the log reaches `LOG_MAX_SIZE_MB`, it is archived to `raid-monitor.log.1` and a new log is started. One archive is kept.

LaunchAgent stdout and stderr are captured separately:

```
~/.local/share/raid-monitor/raid-monitor-stdout.log
~/.local/share/raid-monitor/raid-monitor-stderr.log
```

---

## File layout

```
~/bin/
    raid-monitor.sh                          Main monitoring script
    raid-monitor-notify.app/                 Notification helper (app bundle)
        Contents/
            Info.plist                       Bundle identity (CFBundleIdentifier etc.)
            MacOS/
                raid-monitor-notify          Compiled Swift binary
            Resources/
                AppIcon.icns                 Notification icon (present if AppIcon.png was provided)

~/.config/raid-monitor/
    config.sh                                Your configuration

~/.local/share/raid-monitor/
    state                                    Last known array state
    raid-monitor.log                         Current log
    raid-monitor.log.1                       Previous log (rotated)
    raid-monitor-stdout.log                  LaunchAgent stdout
    raid-monitor-stderr.log                  LaunchAgent stderr

~/Library/LaunchAgents/
    com.airic-lenz.raid-monitor.plist              LaunchAgent definition
```

---

## Manual operation

**Run a poll immediately** (outside the schedule):

```sh
~/bin/raid-monitor.sh
```

**Check current status** — shows live RAID and SMART data, no notification sent:

```sh
~/bin/raid-monitor.sh --status
```

Output example:
```
RAID Monitor v1.0.1 — current status

  Arrays found: 1

  Array:    G-Raid
  UUID:     F71DAB1B-A18D-434D-B275-9A82BB3D1483
  Status:   Online
  Members:
    #0  disk8s2         Online                        SMART: PASSED
    #1  disk9s2         Online                        SMART: PASSED
```

**Verify the installation** and trigger the notification permission prompt:

```sh
~/bin/raid-monitor.sh --test
```

`--test` runs all pre-flight checks, shows the current array status (same as `--status`), then sends a test notification to confirm the full pipeline works. Use `--status` for routine checks.

**Stop monitoring temporarily:**

```sh
launchctl unload ~/Library/LaunchAgents/com.airic-lenz.raid-monitor.plist
```

**Resume monitoring:**

```sh
launchctl load ~/Library/LaunchAgents/com.airic-lenz.raid-monitor.plist
```

---

## Notifications not appearing or not popping out?

**Notifications appear in Notification Center but don't pop out:**

Open **System Settings → Notifications → RAID Monitor** and set **Notification Style** to **Alerts**. Banners auto-dismiss after a few seconds; Alerts stay on screen until you dismiss them. If the style is set to **None**, notifications are delivered silently to Notification Center only and never appear on screen.

If you recently added a custom icon and re-ran `./install.sh`, the notification registration may be stale. Reset it and re-grant permission:

```sh
tccutil reset UserNotifications com.airic-lenz.raid-monitor
~/bin/raid-monitor.sh --test
```

Then set the notification style to **Alerts** again in System Settings.

**Notifications not appearing at all:**

1. Run `~/bin/raid-monitor.sh --test` — if it exits with an error, check the log.
2. Open **System Settings → Notifications → RAID Monitor** and confirm Allow Notifications is **on**.
3. Check that the LaunchAgent is loaded: `launchctl list | grep raid-monitor`
4. Check for errors: `cat ~/.local/share/raid-monitor/raid-monitor-stderr.log`

---

## Limitations

- Monitors **Apple Software RAID** only (`diskutil appleRAID`). Does not support hardware RAID controllers or SoftRAID.
- Does not repair arrays — alerts only.
- SMART passthrough is not available on all USB enclosures — check with `smartctl -H /dev/diskN` before enabling `SMART_ENABLED`.

---

## Project files

| File | Purpose |
|---|---|
| `raid-monitor.sh` | Main monitoring script |
| `notify-helper.swift` | Source for the notification helper — audit before compiling |
| `notify-helper-Info.plist` | App bundle identity (`CFBundleIdentifier`, icon reference, etc.) |
| `AppIcon.png` | *(Optional)* Custom icon source (1024×1024 px) — converted to `.icns` by the installer |
| `config.sh.template` | Config template copied during installation |
| `com.airic-lenz.raid-monitor.plist` | LaunchAgent plist template |
| `install.sh` | Installer / uninstaller |
| `VERSION` | Single source of truth for the version number — read by `install.sh` at install time |
| `technical-design-specification.md` | Full design rationale and specification |
