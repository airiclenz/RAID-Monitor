# macOS Software RAID Monitor — Design Specification

**Project:** macos-raid-monitor
**Version:** 1.3.0
**Status:** Draft
**Last Updated:** 2026-03-25

---

## Changelog

| Version | Change |
|---|---|
| 1.3.0 | Added SMART health monitoring: `_load_smart_data`, `_check_smart_health`, `_compare_smart_alerts`; `SMART_ENABLED` config flag; SMART state persisted per member; `--test` mode reports SMART status; removed SMART from Non-Goals and Future Considerations |
| 1.2.0 | Added custom notification icon pipeline (PNG → icns via sips/iconutil); added `UNNotificationAttachment` thumbnail to work around white-square rendering for ad-hoc signed bundles; corrected `info` interruption level from `.passive` to `.active`; added `lsregister` call to register bundle with Launch Services; introduced `VERSION` file and `APP_VERSION` token substitution for parametric versioning; updated file layout to reflect app bundle structure |
| 1.1.0 | Replaced `osascript` with compiled Swift notification helper; changed state format from JSON to flat key=value; committed to `config.sh` only; simplified log rotation; added USB transient detection; added `--test` mode; fixed LaunchAgent environment; clarified build dependency |
| 1.0.0 | Initial draft |

---

## 1. Overview

A lightweight, dependency-minimal macOS monitoring daemon and notification system for Apple Software RAID arrays (AppleRAID). The tool runs in the background on a schedule, queries array health via `diskutil appleRAID list`, and alerts the user when the array state changes or degrades.

### 1.1 Goals

- Provide timely, actionable alerts when a RAID array enters a Degraded, Failed, or unknown state
- Run silently in the background with zero user interaction required during normal operation
- Require no subscriptions, no third-party RAID software, and no SIP modifications
- Be installable and understandable by a technically proficient macOS user comfortable with Terminal
- Send notifications under the project's own identity — not under a general-purpose system tool

### 1.2 Non-Goals

- This tool does not repair or manage RAID arrays
- This tool does not replace Disk Utility or `diskutil`
- This tool is not a GUI application
- This tool does not support hardware RAID controllers or third-party RAID software (SoftRAID, etc.)
- This tool does not repair or manage RAID arrays based on SMART data

---

## 2. Environment

| Property | Value |
|---|---|
| Target OS | macOS 13 Ventura and later |
| Architecture | Apple Silicon (arm64) and Intel (x86_64) |
| Shell | zsh (default macOS shell) |
| Privileged access | Not required (`diskutil appleRAID list` runs as standard user) |
| Installation method | Manual (copy files + compile helper + load LaunchAgent) |
| Runtime dependencies | None |
| Build dependency | Xcode Command Line Tools (`swiftc`) — one-time, for compiling the notification helper |

### 2.1 Build Dependency: Xcode Command Line Tools

The notification helper (`raid-monitor-notify`) is a small Swift binary compiled once during installation. `swiftc` ships with Xcode Command Line Tools and is present on any Mac where a developer has run `xcode-select --install`. It is not required at runtime — only during the one-time install step.

To verify: `swiftc --version`
To install if missing: `xcode-select --install`

---

## 3. RAID Array Context

The initial target environment uses the following setup:

- **Connection:** USB — no Thunderbolt
- **Array type:** Apple Software RAID 1 (Mirror)
- **Filesystem:** Mac OS Extended (Journaled) / HFS+
- **Array name:** G-Raid (may vary; tool must handle any array name)
- **Number of arrays:** 1 (v1.0); multi-array support considered for v2.0

---

## 4. Functional Requirements

### 4.1 Array State Detection

The monitor must detect and distinguish the following AppleRAID array states:

| State | Meaning | Alert required |
|---|---|---|
| `Online` | All members healthy, array fully operational | No (log only) |
| `Degraded` | One or more members failed or rebuilding | **Yes — Warning** |
| `Rebuilding` | Member is being rebuilt (sub-state of Degraded) | **Yes — Info** |
| `Failed` | Array is non-functional | **Yes — Critical** |
| `Unknown` / parse error | Could not determine state | **Yes — Warning** |
| Array disappeared | Previously seen array no longer listed | **Yes — Critical** (after transient check — see §4.7) |

### 4.2 State Persistence

- The monitor must persist the **last known state** to disk so that:
  - Alerts are only sent on **state transitions**, not on every poll
  - On daemon restart, prior state is correctly recalled
- State file location: `~/.local/share/raid-monitor/state`
- State file format: flat key=value, human-readable, sourceable in bash without external tools

**Rationale for flat format over JSON:** The implementation is bash/zsh with no external runtime dependencies. Parsing JSON reliably in pure bash requires either `python3` (not guaranteed on all systems) or `jq` (not standard). A flat key=value format is natively readable via `source`, `grep`, and parameter expansion without any parser.

**State file schema (example):**
```
# raid-monitor state — do not edit manually
last_checked=2026-03-25T14:32:00Z
array_count=1
array_0_uuid=F71DAB1B-A18D-434D-B275-9A82BB3D1483
array_0_name=G-Raid
array_0_status=Online
array_0_member_count=2
array_0_member_0_dev=disk8s2
array_0_member_0_status=Online
array_0_member_1_dev=disk9s2
array_0_member_1_status=Online
```

State values containing spaces must be quoted (e.g. `array_0_name="My RAID"`). The file is written atomically: written to a `.tmp` file, then renamed, so a crash mid-write never leaves a corrupt state.

### 4.3 Notification Delivery

#### 4.3.1 Notification Helper — Primary Channel (Required, v1.0)

Notifications are delivered via `raid-monitor-notify`, a small Swift CLI binary compiled from source during installation. This binary uses the macOS `UserNotifications` framework under its own bundle identifier (`com.airic-lenz.raid-monitor`), so the notification permission is granted to **"RAID Monitor"** specifically — not to Script Editor, osascript, or any other general-purpose system tool.

**Rationale:** `osascript display notification` registers notification permission under Script Editor, a general-purpose Apple scripting tool with broad capabilities. Granting Script Editor notification permission is imprecise. The Swift helper provides a dedicated, auditable, single-purpose identity for all notifications from this project.

**Helper behaviour:**
- CLI interface: `raid-monitor-notify --title "…" --subtitle "…" --body "…" --level info|warning|critical`
- On first invocation, macOS shows a one-time system prompt: *"RAID Monitor" would like to send notifications* — the user approves once
- After that, all notifications are delivered silently by the LaunchAgent without user interaction
- The helper exits after posting the notification (no persistent process)
- Source file: `notify-helper.swift` (included in the project, auditable)
- Compiled with ad-hoc code signature so macOS accepts it without requiring a paid developer account:
  ```
  swiftc notify-helper.swift -o raid-monitor-notify
  codesign --sign - --identifier "com.airic-lenz.raid-monitor" raid-monitor-notify
  ```

**Notification content:**
- Title: `RAID Alert — <array name>`
- Subtitle: `Status: <state>`
- Body: member summary + timestamp
- Sound: default system alert sound for warning/critical; none for info

#### 4.3.2 Email Notification (Optional, v1.0 — flag-controlled)

- Send plain-text email via `sendmail` or `msmtp` if configured
- Only attempted if email is explicitly configured in the config file
- Must not fail silently — log delivery errors

### 4.4 Logging

- All events (polls, state changes, errors) must be written to a log file
- Log location: `~/.local/share/raid-monitor/raid-monitor.log`
- Log format: ISO 8601 timestamps, plain text, one event per line
- Log rotation: when the log exceeds `LOG_MAX_SIZE_MB`, the current log is renamed to `raid-monitor.log.1` and a new log is started. Only one rotated archive is kept (i.e. `.log.1` is overwritten if present)
- Rotation is performed by the script itself at the start of each poll, before writing new entries
- Logs must be readable without special tooling (plain `cat` / `tail`)

**Rationale for simplified rotation:** Implementing 30-day retention in pure bash requires tracking per-line timestamps or using `find` with `-mtime`, both fragile across timezones and DST. Size-based rotation with one archive is simple, reliable, and sufficient for a single-user daemon.

### 4.5 Poll Interval

- Default poll interval: **5 minutes**
- Configurable in the config file (minimum: 1 minute, maximum: 60 minutes)
- Poll must not drift significantly — use LaunchAgent `StartInterval` for scheduling

### 4.6 Configuration File

- Location: `~/.config/raid-monitor/config.sh`
- Sourced by `raid-monitor.sh` using `source` / `.`
- Must be created from a documented template during installation
- If the config file is missing, all defaults are used and a warning is logged

**Rationale for shell format:** The main script is bash/zsh. Sourcing a `.sh` config file requires zero parsing. A JSON or TOML config would require an external parser or fragile hand-rolled bash parsing. The `.sh` format is standard for shell-based tools (e.g. `/etc/default/`, `/etc/sysconfig/`).

| Setting | Default | Description |
|---|---|---|
| `POLL_INTERVAL_SECONDS` | `300` | How often to check (seconds) |
| `NOTIFY_ON_ONLINE` | `false` | Alert when array returns to Online state |
| `EMAIL_ENABLED` | `false` | Enable email notifications |
| `EMAIL_TO` | `""` | Recipient address |
| `EMAIL_FROM` | `""` | Sender address |
| `LOG_MAX_SIZE_MB` | `5` | Max log file size before rotation |
| `ARRAY_UUID_FILTER` | `""` | Optional: monitor only this specific array UUID |
| `TRANSIENT_RECHECK_SECONDS` | `30` | Delay before confirming array disappearance (see §4.7) |
| `SMART_ENABLED` | `false` | Enable SMART health checks per member disk (see §4.9). Requires `smartmontools`. |

### 4.7 USB Transient Disappearance Handling

**Problem:** The RAID array is connected via USB. After macOS wakes from sleep, the USB device may take several seconds to re-enumerate. If the script fires immediately after wake, it may observe the array as missing and generate a false Critical alert.

**Behaviour:**
- When an array that was previously `Online` is no longer listed in `diskutil appleRAID list` output, the script must **not** immediately alert
- Instead, the script waits `TRANSIENT_RECHECK_SECONDS` (default: 30) and re-runs `diskutil appleRAID list`
- Only if the array is still absent after the re-check does the script fire the Critical "Array disappeared" alert
- The transient check is logged: `[INFO] Array F71DAB1B not found — waiting 30s to confirm (possible wake from sleep)`
- If the array reappears on re-check, this is logged as: `[INFO] Array F71DAB1B reappeared after transient absence — no alert`

**Note:** This logic applies only to the `Online → Disappeared` transition. If the array is already in a Degraded or Failed state and then disappears, alert immediately without re-check.

### 4.8 Manual Test Mode

The script must support a `--test` flag for verifying the installation:

```
raid-monitor.sh --test
```

**Behaviour in test mode:**
- Skips `diskutil` query and state comparison
- Fires a test Notification Center alert: *"RAID Monitor test — installation verified"*
- Writes a test entry to the log file
- Sends a test email if `EMAIL_ENABLED=true`
- Exits 0 on success, 1 on any failure
- Does not read or modify `state`

This allows the user to verify the full notification pipeline immediately after installation, before the first scheduled poll.

### 4.9 SMART Health Monitoring (optional, flag-controlled)

When `SMART_ENABLED=true`, the monitor runs `smartctl -H /dev/<parent-disk>` on each RAID member disk after every `diskutil` poll and persists the result in the state file.

**Parent disk resolution:** RAID member device nodes are partition references (e.g. `disk8s2`). SMART operates on the whole disk. The partition suffix is stripped: `diskNsM` → `diskN`.

**Health status values:**

| Value | Meaning |
|---|---|
| `PASSED` | SMART self-assessment passed — no imminent failure predicted |
| `FAILED` | SMART predicts drive failure — immediate action required |
| `UNSUPPORTED` | Device does not expose SMART data (common on USB enclosures without passthrough) |
| `UNKNOWN` | `smartctl` ran but returned unrecognisable output |

**Alert behaviour:**

| Transition | Level | Action |
|---|---|---|
| Any → `FAILED` | Critical | Notification + email (if configured) |
| `PASSED` → `UNKNOWN` | Warning | Notification |
| Any → `UNSUPPORTED` | — | Log only, no alert |
| No change | — | Log only |

Alerts fire only on **transitions** — SMART state is persisted per member in the state file so a drive that was already `FAILED` on the previous poll does not re-alert.

**Dependency:** Requires `smartmontools` (`brew install smartmontools`). If `SMART_ENABLED=true` and `smartctl` is not found, a warning is logged and SMART checks are skipped for that poll — the daemon continues normally.

**USB enclosure caveat:** Many USB bridges do not expose SMART passthrough. All members will show `UNSUPPORTED` and no alerts will fire. Users should verify with `smartctl -H /dev/diskN` before enabling.

**State file additions (per member when SMART_ENABLED=true):**
```
array_0_member_0_smart=PASSED
array_0_member_1_smart=PASSED
```

---

## 5. Non-Functional Requirements

### 5.1 Reliability
- The script must not crash or produce unhandled errors under normal macOS operation
- If `diskutil` is unavailable or returns unexpected output, the script must log the error and exit cleanly without corrupting the state file
- The monitor must survive macOS reboots (LaunchAgent auto-restarts)
- State file writes are atomic (write to `.tmp`, rename) to prevent corruption on crash

### 5.2 Performance
- CPU and memory impact must be negligible — the script should complete each poll in under 2 seconds on typical hardware (excluding the transient re-check sleep, which is intentional)
- No persistent background process beyond the LaunchAgent scheduler itself

### 5.3 Security
- The script must not require root / sudo
- The script must not transmit data externally except via explicitly configured email
- No API keys, cloud services, or telemetry of any kind
- The notification helper source (`notify-helper.swift`) is included in the repository so the user can audit exactly what is compiled and run

### 5.4 Portability
- Written in **bash or zsh** — no Python, Ruby, or Node.js runtime required
- Must work on both Apple Silicon and Intel Macs without modification
- `swiftc` is a build-time dependency only; the compiled binary has no runtime Swift dependencies beyond what ships with macOS

---

## 6. Architecture

```
┌─────────────────────────────────────┐
│         launchd (macOS)             │
│   com.airic-lenz.raid-monitor.plist       │
│   StartInterval: 300s               │
└────────────────┬────────────────────┘
                 │ spawns every N seconds
                 ▼
┌─────────────────────────────────────┐
│        raid-monitor.sh              │
│                                     │
│  1. Load config                     │
│  2. Run: diskutil appleRAID list    │
│  3. Parse output → current state    │
│  4. Load state file → prior state   │
│  5. Compare states                  │
│  6. If disappeared: re-check after  │
│     TRANSIENT_RECHECK_SECONDS       │
│  7. If changed → notify + log       │
│  8. Write updated state (atomic)    │
└──────┬──────────────┬───────────────┘
       │              │
       ▼              ▼
 raid-monitor-notify  sendmail / msmtp
 (Swift helper —      (Email — optional)
  UserNotifications)
```

---

## 7. File & Directory Layout

```
~/.config/raid-monitor/
    config.sh                    # User configuration (sourced by script)

~/.local/share/raid-monitor/
    state                        # Persisted last-known state (flat key=value)
    state.tmp                    # Atomic write staging file (transient)
    raid-monitor.log             # Rolling log file (current)
    raid-monitor.log.1           # Previous log (rotated)
    raid-monitor-stdout.log      # LaunchAgent stdout capture
    raid-monitor-stderr.log      # LaunchAgent stderr capture

~/Library/LaunchAgents/
    com.airic-lenz.raid-monitor.plist  # LaunchAgent definition

~/bin/
    raid-monitor.sh                          # Main monitoring script
    raid-monitor-notify.app/                 # Notification helper (app bundle)
        Contents/
            Info.plist                       # Bundle identity (CFBundleIdentifier, icon ref, version)
            MacOS/
                raid-monitor-notify          # Compiled Swift binary
            Resources/
                AppIcon.icns                 # Notification corner icon (if AppIcon.png was provided)
```

> **Why an app bundle?** `UNUserNotificationCenter` requires a `CFBundleIdentifier` in the calling process's `Info.plist`. A bare CLI binary has none and crashes with `SIGABRT`. Placing the binary inside an `.app` bundle with an `Info.plist` provides the required bundle identity without a full GUI app.

**Source files (in project repository):**
```
raid-monitor.sh                  # Main script (contains APP_VERSION token, substituted at install time)
notify-helper.swift              # Swift source for notification helper (auditable before compile)
notify-helper-Info.plist         # App bundle Info.plist template (contains APP_VERSION token)
config.sh.template               # Config template
com.airic-lenz.raid-monitor.plist      # LaunchAgent plist template (contains INSTALL_PATH and USERNAME tokens)
install.sh                       # Installer / uninstaller
VERSION                          # Single source of truth for the version number
AppIcon.png                      # (Optional) Custom icon source — 1024×1024 px PNG
README.md
technical-design-specification.md
```

---

## 8. Installation

Installation is handled by `install.sh`. No installer package (`.pkg`) is required.

**Prerequisites:**
- Xcode Command Line Tools: `xcode-select --install`

**Steps:**

```sh
# 1. (Optional) Place AppIcon.png (1024×1024 px) in the project directory for a custom icon
# 2. Run the installer from the project directory:
./install.sh
```

`install.sh` performs in order:
1. Pre-flight checks — verifies all source files are present and `swiftc`/`codesign` are available
2. Reads the `VERSION` file and substitutes the `APP_VERSION` token in `raid-monitor.sh` and `notify-helper-Info.plist` during installation
3. Copies `raid-monitor.sh` to `~/bin/` (with token substitution)
4. Compiles `notify-helper.swift` → `~/bin/raid-monitor-notify.app/Contents/MacOS/raid-monitor-notify`
5. Installs `notify-helper-Info.plist` to the app bundle (with version token substituted)
6. If `AppIcon.png` is present: converts it to `.icns` using `sips` + `iconutil`, installs to `Resources/AppIcon.icns`, and copies the PNG to `Resources/notification-icon.png`
7. Ad-hoc code-signs the entire app bundle: `codesign --sign - --force --deep`
8. Registers the bundle with Launch Services (`lsregister`) so macOS resolves the corner icon in notification banners
9. Installs config template to `~/.config/raid-monitor/config.sh` (only if not already present)
10. Substitutes `INSTALL_PATH` and `USERNAME` tokens in the LaunchAgent plist and installs it
11. Loads the LaunchAgent via `launchctl load`

**Icon conversion note:** `iconutil` requires the source directory to end exactly in `.iconset`. The installer creates `$(mktemp -d)/AppIcon.iconset` (a named subdirectory, not the mktemp output itself) to satisfy this constraint.

**First-run notification grant:**
```sh
~/bin/raid-monitor.sh --test
# macOS shows a one-time prompt: '"RAID Monitor" would like to send notifications' — click Allow
```

**Uninstallation:**
```sh
./install.sh --uninstall
# Optionally removes logs and state directory (prompted)
```

---

## 9. LaunchAgent Plist Specification

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.airic-lenz.raid-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>INSTALL_PATH/raid-monitor.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/USERNAME</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/USERNAME/.local/share/raid-monitor/raid-monitor-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/USERNAME/.local/share/raid-monitor/raid-monitor-stderr.log</string>
</dict>
</plist>
```

> `INSTALL_PATH` and `USERNAME` must be replaced with absolute paths during installation. Tilde (`~`) and `$HOME` expansion does **not** occur in launchd plist values — absolute paths are required throughout.

**Rationale for explicit `HOME` and `PATH`:** launchd does not guarantee these variables are set in a LaunchAgent's environment. Without `HOME`, any script using `~` or `$HOME` for config/state paths will silently fail. Without an explicit `PATH`, `diskutil` and other tools may not be found.

---

## 10. Parsing Logic

`diskutil appleRAID list` output is plain text. The parser must:

1. Detect the line `AppleRAID sets (N found)` — if N = 0, all previously known arrays have disappeared → trigger transient check (§4.7), then alert if confirmed
2. For each array block, extract:
   - `Name`
   - `Unique ID`
   - `Status` (Online / Degraded / Failed)
   - `Device Node`
   - For each member: `#`, `DevNode`, `UUID`, `Status`, `Size`
3. Handle the `Rebuilding` sub-state: member status field contains `% (Rebuilding)` — extract percentage
4. Be tolerant of extra whitespace and minor formatting differences across macOS versions

**Example member status values to handle:**
- `Online`
- `8% (Rebuilding)`
- `Failed`
- `Missing`

---

## 11. Alert Message Format

### Notification Center (raid-monitor-notify)
```
Title:    RAID Alert — G-Raid
Subtitle: Status: Degraded
Body:     Member disk9s2 is Rebuilding (8%). Check Disk Utility.
          [2026-03-25 14:32]
```

### Email (plain text)
```
Subject: [RAID Monitor] G-Raid — Status: Degraded

Array:    G-Raid
UUID:     F71DAB1B-A18D-434D-B275-9A82BB3D1483
Status:   Degraded
Time:     2026-03-25 14:32:00 UTC

Members:
  #0  disk8s2  Online
  #1  disk9s2  8% (Rebuilding)

Previous status: Online
Action required: Monitor rebuild progress. Run:
  diskutil appleRAID list

-- raid-monitor vX.Y.Z
```

---

## 12. Error Handling

| Condition | Behaviour |
|---|---|
| `diskutil` not found | Log critical error, send notification, exit 1 |
| `diskutil` returns empty output | Log warning, do not update state, exit 0 |
| State file missing | Treat as first run — create new state, no alert |
| State file corrupt / unreadable | Log warning, treat as first run, overwrite |
| Array disappeared (transient) | Wait `TRANSIENT_RECHECK_SECONDS`, re-check before alerting (§4.7) |
| Notification helper not found | Log critical error, attempt email fallback if configured, exit 1 |
| Notification helper exits non-zero | Log error, attempt email fallback if configured |
| Email delivery fails | Log error, do not retry in same poll cycle |
| Config file missing | Use all defaults, log warning |
| State write fails (disk full, permissions) | Log critical error, do not overwrite existing state, exit 1 |

---

## 13. notify-helper.swift — Design Notes

The helper is a minimal Swift command-line program. Key design points:

- Uses `UserNotifications` framework (`import UserNotifications`)
- Calls `requestAuthorization(options: [.alert, .sound])` on first run to trigger the one-time system permission prompt
- Posts a `UNNotificationRequest` with `trigger: nil` (deliver immediately)
- Uses a `DispatchSemaphore` to block until the notification is posted, then exits
- Bundle identifier is set via ad-hoc code signature at install time — no paid Apple Developer account required
- The `--level` flag maps to notification `interruptionLevel`: `.active` (info, warning), `.timeSensitive` (critical — breaks Focus/Do Not Disturb)
- Sound: default alert sound for warning and critical; silent for info
- Exit codes: `0` success, `1` authorisation denied, `2` posting error, `3` delivery timeout

**Security:** The source is included in the repository. Users are encouraged to read `notify-helper.swift` before compiling. The binary is compiled locally from that source — no pre-built binary is distributed.

---

## 14. Future Considerations (v2.0)

The following are explicitly out of scope for v1.0 but should be kept in mind when structuring the code:

- **Multi-array support** — monitor more than one AppleRAID set simultaneously
- **Rebuild progress tracking** — log and alert on stalled rebuilds (percentage not increasing over N polls)
- **Menu bar status indicator** — at this point a full native Swift app is warranted; the notification helper can be promoted to a menu bar app
- **Structured JSON logging** — for ingestion into log aggregators
- **Homebrew formula** — simplify installation (would bundle the pre-compiled notify helper)

---

## 15. Low-Hanging Improvements

The items below are small, self-contained changes that add meaningful value without restructuring the tool. They are ordered roughly by effort, smallest first.

### 15.1 Alert on first run if array is already degraded

**Current behaviour:** On first run (no prior state file), the monitor records the current state and logs "first run — no alerts." If the array is already Degraded or Failed at install time, the user receives no notification until the state changes again.

**Proposed change:** After a first-run state write, check whether any array's status is not `Online`. If so, fire a notification immediately with the current status. This requires a single additional block after `_write_state` on the first-run path — no new config setting needed.

### 15.2 `--status` CLI flag

**Current behaviour:** Checking the current RAID state requires running `diskutil appleRAID list` directly.

**Proposed change:** Add `raid-monitor.sh --status` to print a human-readable summary of the last persisted state (from the state file) alongside the current wall-clock age of that state. Implementation: read the state file, format output, exit. No `diskutil` call needed. Useful for quick checks without waiting for the next poll.

### 15.3 Per-member status tracking in state file

**Current behaviour:** Member status values are written to the state file but not compared between polls. Only the array-level `Status` field drives alerts.

**Proposed change:** During `_compare_and_alert`, also diff per-member statuses. Alert (warning) when a member transitions from `Online` to any other status, even if the array-level status has not yet changed (which can happen briefly during degradation). This gives earlier warning at no additional polling cost.

### 15.4 Suppress repeated alerts for the same degraded state

**Current behaviour:** An alert fires once when the status changes (e.g. Online → Degraded). If the daemon restarts while the array is still Degraded, a new alert fires because the state transitions from no-prior-state to Degraded.

**Proposed change:** On first run (or after restart), suppress alerts for already-degraded states — only alert if the persisted state was previously `Online` (or is genuinely new). Alternatively, add a `last_alerted_status` key to the state file so repeated daemon restarts do not re-fire alerts for the same condition.

### 15.5 Stalled rebuild detection

**Current behaviour:** A "Rebuilding" alert fires once when rebuilding begins. No further alerts fire during the rebuild unless the state changes.

**Proposed change:** Track the rebuild percentage across polls. If the percentage has not increased after N consecutive polls (configurable, default: 3), fire a warning: "Rebuild appears stalled at X%." Implementation: add `array_N_rebuild_pct` and `array_N_rebuild_stall_count` to the state file. This is meaningful for USB enclosures where a stalled rebuild may indicate a loose connection.

### 15.6 `launchctl bootstrap` / `bootout` on macOS 13+

**Current behaviour:** `install.sh` uses `launchctl load` / `unload`, which are deprecated in macOS 13 Ventura (they still work but print deprecation warnings in some contexts).

**Proposed change:** Use `launchctl bootstrap gui/$(id -u) "$DEST_PLIST"` and `launchctl bootout gui/$(id -u) "$DEST_PLIST"` instead. These are the modern equivalents for user-domain LaunchAgents and suppress the deprecation path. The installer can detect macOS version via `sw_vers -productVersion` to apply the correct form.

### 15.7 Configurable notification sound

**Current behaviour:** Sound behaviour is fixed in `notify-helper.swift`: default system alert sound for warning/critical, silent for info.

**Proposed change:** Expose a `NOTIFY_SOUND` config option (`true`/`false`, default `true`). Pass a `--sound` flag to the notify helper, which then conditionally sets `content.sound`. Useful for users who prefer silent notifications alongside the Focus / Notification Center UI.

---

## 16. Acceptance Criteria

The implementation is considered complete for v1.0 when:

- [ ] `diskutil appleRAID list` output is correctly parsed for Online, Degraded, Rebuilding, and Failed states
- [ ] A Notification Center alert fires within one poll cycle of a state change, attributed to "RAID Monitor" in System Settings → Notifications
- [ ] No alert fires when the array remains in the same state across consecutive polls
- [ ] No false "disappeared" alert fires when the array is transiently absent (e.g. after wake from sleep)
- [ ] State is correctly restored after a daemon restart
- [ ] The LaunchAgent survives a macOS reboot and resumes polling
- [ ] All events are written to the log file with correct timestamps
- [ ] `--test` mode fires a notification and exits 0 without touching state
- [ ] Installation and uninstallation can be completed by following the documented steps alone
- [ ] The script produces no errors when run manually in Terminal on macOS Ventura or later
- [ ] State file writes are atomic (no corrupt state on crash/interrupt)

---

*End of specification*
