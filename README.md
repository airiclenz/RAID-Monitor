# RAID Integrity Monitor

A macOS daemon that detects silent data corruption (bit-rot) on your files and monitors your Apple Software RAID array health. Sends native macOS notifications the moment something goes wrong.

No subscriptions. No third-party agents. No SIP modifications. Runs silently as a daily LaunchAgent.

---

## How it works

Each night, RAID Integrity Monitor performs a four-phase scan:

1. **RAID health check** — queries `diskutil appleRAID list` for array and member status
2. **Directory walk** — crawls your watch paths and classifies every file as new, modified, or stable
3. **Hash new and modified files** — computes SHA-256 for any file whose size or modification date changed
4. **Rolling re-verification** — gradually re-hashes previously seen stable files, cycling through the full library every 30 days (configurable)

A **hash mismatch on a stable file** — where the modification date and size have not changed — is the primary corruption signal. Bit-rot corrupts data blocks on disk but leaves filesystem metadata (mtime, size) untouched, so the filesystem itself never reports a problem. By re-hashing and comparing against the stored hash, RAID Integrity Monitor catches corruption that would otherwise go unnoticed until you try to open the file.

---

## Requirements

| | |
|---|---|
| macOS | 13 Ventura or later |
| Architecture | Apple Silicon or Intel |
| Xcode | Required to build (free from the App Store, or via `xcode-select --install`) |

Xcode is only needed once to compile the binary. The running daemon has no dependencies.

---

## Installation

### 1. Configure your watch paths

Before installing, open `config.json.template` and set the directories you want to monitor:

```json
"watchPaths": [
  "/Volumes/G-Raid/Photos",
  "/Volumes/G-Raid/Projects"
]
```

You can also set a replica database path for an extra copy of the manifest synced to iCloud Drive or another location:

```json
"database": {
  "primary": "~/.local/share/raid-integrity-monitor/manifest.db",
  "replica": "~/Library/Mobile Documents/com~apple~CloudDocs/raid-integrity-monitor/manifest.db"
}
```

### 2. Run the installer

```sh
cd IntegrityMonitor
./install.sh
```

The installer:
- Builds the project (`swift build -c release`)
- Copies the `raid-integrity-monitor` binary to `~/bin/`
- Builds and signs the `raid-integrity-monitor-notify.app` bundle
- Converts `AppIcon.png` to `.icns` if present (place a 1024×1024 PNG in the project root)
- Installs the config template to `~/.config/raid-integrity-monitor/config.json` (fresh install), or merges new settings into your existing config (reinstall — your edits are never overwritten)
- Installs and loads the LaunchAgent (runs every `raidCheckIntervalMinutes`, default 5 min)

### 3. Grant Full Disk Access

This is required for RAID Integrity Monitor to scan your files.

Open **System Settings → Privacy & Security → Full Disk Access** and add:
```
~/bin/raid-integrity-monitor
```

### 4. Run the initial scan

On first run, scan your files to build the baseline manifest:

```sh
raid-integrity-monitor --mode scan
```

This may take a while depending on the number of files. Progress is displayed in the terminal.

### 5. Verify the setup

```sh
raid-integrity-monitor --mode test
```

On first run, macOS shows a one-time prompt:

> **"RAID Integrity Monitor" would like to send notifications**

Click **Allow**. Then in **System Settings → Notifications → RAID Integrity Monitor**, set the style to **Alerts** (not Banners) so corruption notifications stay on screen until dismissed.

### 6. Confirm the agent is running

```sh
launchctl list | grep raid-integrity-monitor
```

---

## Uninstallation

```sh
./install.sh --uninstall
```

Unloads the LaunchAgent and removes all installed files. You are asked whether to also delete the data directory (logs and database).

---

## Configuration

The config file lives at:

```
~/.config/raid-integrity-monitor/config.json
```

Edit it in any text editor. Changes take effect on the **next scan** — no reload needed.

When you reinstall after an update, any new keys introduced in `config.json.template` are automatically merged into your existing config. Your edits are never overwritten.

### All settings

#### Watch paths

```json
"watchPaths": ["/Volumes/G-Raid/Photos"]
```

List of directories to scan. Must exist at install time. Subdirectories are scanned recursively.

#### Exclusions

```json
"exclude": {
  "pathPatterns": [".DS_Store", "*.tmp"],
  "directoryPatterns": ["*.lrdata", ".Spotlight-V100"],
  "minSizeBytes": 0,
  "maxSizeBytes": null
}
```

| Field | Description |
|---|---|
| `pathPatterns` | Glob patterns matched against the full path and filename. Matching files are skipped. |
| `directoryPatterns` | Glob patterns matched against directory names. Matching directories and all their contents are skipped entirely (efficient for large preview caches like Lightroom's `.lrdata`). |
| `minSizeBytes` / `maxSizeBytes` | Skip files outside this size range. `null` means no limit. |

Pattern matching is case-insensitive (appropriate for HFS+). Standard glob syntax: `*` matches any sequence of characters, `?` matches one character.

#### Hash algorithm

```json
"hashAlgorithm": "sha256"
```

Currently only `sha256` is supported. The algorithm name is stored alongside every hash, so future migration to a stronger algorithm is possible via `--mode upgrade-hash`.

#### Database

```json
"database": {
  "primary": "~/.local/share/raid-integrity-monitor/manifest.db",
  "replica": null
}
```

`primary` is the working database. `replica` is an optional second copy written in parallel — useful for backing up the manifest to iCloud Drive or another synced location. Set to `null` to disable. If the replica is unavailable, the scan continues using only the primary.

#### Notifications

```json
"notifications": {
  "onCorruption": true,
  "onRAIDDegraded": true,
  "onMissingFile": false,
  "onScanComplete": false,
  "onScanCompleteWithIssues": true
}
```

| Setting | Default | Description |
|---|---|---|
| `onCorruption` | `true` | Alert when a file's content changes with no modification date change (bit-rot). Always sent — cannot be silenced. |
| `onRAIDDegraded` | `true` | Alert when the RAID array enters Degraded or Failed state. |
| `onMissingFile` | `false` | Alert when a previously tracked file no longer exists. Off by default to avoid noise from files that are intentionally deleted. |
| `onScanComplete` | `false` | Alert when every scan completes, even with no issues. |
| `onScanCompleteWithIssues` | `true` | Alert when a scan completes and found corruption or missing files. |

#### Performance

```json
"performance": {
  "maxHashThreads": 2,
  "volumeThreadOverrides": {},
  "dbBatchSize": 500,
  "maxVerificationsPerRun": 1000
}
```

| Setting | Default | Description |
|---|---|---|
| `maxHashThreads` | `2` | Global fallback for parallel hashing threads. Used when auto-detection fails or a volume has no override. |
| `volumeThreadOverrides` | `{}` | Per-volume thread overrides, keyed by mount point (e.g. `{"/Volumes/G-Raid": 1, "/Volumes/FastSSD": 8}`). Takes priority over auto-detected defaults. |
| `dbBatchSize` | `500` | Number of records written to the database per transaction. |
| `maxVerificationsPerRun` | `1000` | Maximum number of stable files re-verified per scan. Must be at least `total files / verificationIntervalDays` to complete a full cycle on time. See **Tuning for large libraries** below. |

**Disk type auto-detection:** At scan start, the tool runs `diskutil info` on each volume's mount point and reads the `Solid State:` field. SSDs automatically get 4 hash threads, HDDs get 1. Manual overrides in `volumeThreadOverrides` take priority. If detection fails (e.g. network volumes), the global `maxHashThreads` is used as fallback. Detected volumes and their thread counts are logged at info level.

#### Logging

```json
"logging": {
  "logPath": "~/.local/share/raid-integrity-monitor/raid-integrity-monitor.log",
  "level": "info",
  "maxLogSizeBytes": 10485760
}
```

| Setting | Description |
|---|---|
| `logPath` | Location of the main log file. |
| `level` | Log verbosity: `debug`, `info`, `warn`, `error`. |
| `maxLogSizeBytes` | Log size before rotation (default 10 MB). One archive (`.log.1`) is kept. |

#### RAID

```json
"raid": {
  "enabled": true,
  "memberDisks": []
}
```

| Setting | Description |
|---|---|
| `enabled` | Whether to include a RAID health check in each scan. Set to `false` to run file-only scans. |
| `memberDisks` | Parent disk identifiers (e.g. `["disk8", "disk9"]`) to check SMART health via `diskutil info`. Leave empty to skip SMART checks. Not all USB enclosures expose SMART data — test with `diskutil info /dev/diskN` first. |

To find your member disk identifiers:

```sh
diskutil appleRAID list
```

Look for `DevNode` entries like `disk8s2` — the parent disk is `disk8`.

#### Schedule

```json
"schedule": {
  "raidCheckIntervalMinutes": 5,
  "fileScanIntervalHours": 24,
  "verificationIntervalDays": 30
}
```

| Setting | Default | Description |
|---|---|---|
| `raidCheckIntervalMinutes` | `5` | How often the LaunchAgent runs and checks RAID health. Also controls how quickly a degraded array is detected. |
| `fileScanIntervalHours` | `24` | Minimum hours between file integrity scans. The binary checks the last completed scan timestamp and only runs file phases when this interval has elapsed. |
| `verificationIntervalDays` | `30` | How often each file is re-verified. Every file in your library is re-hashed at least once per interval, spread evenly across scans. |

The LaunchAgent runs every `raidCheckIntervalMinutes`. Each invocation always performs a RAID health check (fast — just `diskutil` calls). File integrity scanning (directory walk, hashing, re-verification) only runs when `fileScanIntervalHours` has elapsed since the last completed scan. This gives you frequent RAID monitoring without redundant file hashing.

Changing `raidCheckIntervalMinutes` requires a reinstall (`./install.sh`) to update the LaunchAgent schedule. All other config changes take effect immediately on the next scan.

#### Tuning for large libraries

The default `maxVerificationsPerRun` (1000) is designed for small libraries. For large libraries you need to increase it, otherwise a full verification cycle will take far longer than `verificationIntervalDays`.

The key formula:

```
maxVerificationsPerRun  >=  total files / verificationIntervalDays
```

For example, with 1.3 million files and a 60-day cycle: 1,300,000 / 60 = ~22,000 files per daily scan.

**Disk type is auto-detected** — spinning HDDs automatically get 1 hash thread and SSDs get 4 (see **Performance** above). If you monitor volumes of mixed types, the tool handles each volume independently. You only need `volumeThreadOverrides` if the auto-detected defaults don't suit your setup:

```json
"performance": {
    "volumeThreadOverrides": {
        "/Volumes/G-Raid": 1,
        "/Volumes/FastSSD": 8
    },
    "maxVerificationsPerRun": 25000
},
"schedule": {
    "verificationIntervalDays": 60
}
```

If all your volumes are the same type, you can simply set `maxHashThreads` as a global fallback (used when auto-detection fails):

```json
"performance": {
    "maxHashThreads": 1,
    "maxVerificationsPerRun": 25000
}
```

After your first few scans, check how long Phase 3 (re-verification) takes:

```sh
grep "Phase 3" ~/.local/share/raid-integrity-monitor/raid-integrity-monitor.log
```

Adjust `maxVerificationsPerRun` up or down to fit your preferred daily time budget. If you ever need an immediate full check regardless of schedule, use `--mode verify`.

---

## Operation modes

Run any mode manually:

```sh
raid-integrity-monitor --mode <mode>
```

| Mode | Description |
|---|---|
| `scheduled` | LaunchAgent mode (default): always runs RAID check, runs file scan only when `fileScanIntervalHours` has elapsed since the last scan |
| `scan` | Full scan: RAID check + file integrity — runs everything immediately regardless of schedule. New files are indexed automatically. |
| `scan-files` | File integrity only — no RAID check |
| `scan-raid` | RAID health check only — prints current array status |
| `verify` | Re-verify all tracked files against stored hashes in one run — full integrity check on demand |
| `report` | Print a summary of the last scan |
| `test` | Verify the setup and send a test notification |
| `upgrade-hash` | Migrate all stored hashes to a new algorithm: `--from sha256 --to <new>` |
| `verify-db` | Compare row counts between primary and replica databases |

### Use a different config file

```sh
raid-integrity-monitor --config /path/to/other-config.json --mode scan
```

---

## Alerts

| Event | Severity | Notification? |
|---|---|---|
| File content changed with no mtime/size change (bit-rot) | Critical | Always |
| RAID array Degraded or Failed | Warning / Critical | If `onRAIDDegraded: true` |
| Drive SMART failure | Critical | If `memberDisks` is configured |
| Previously tracked file no longer exists | Warning | If `onMissingFile: true` |
| Scan complete with issues | Warning | If `onScanCompleteWithIssues: true` |
| Scan complete, no issues | Info | If `onScanComplete: true` |

**Critical** alerts use macOS Time Sensitive interruption level and break through Focus / Do Not Disturb.

---

## Logs and data files

```
~/.local/share/raid-integrity-monitor/
    manifest.db                   SQLite manifest database (all file hashes)
    raid-integrity-monitor.log         Main log (rotated at maxLogSizeBytes)
    raid-integrity-monitor.log.1       Previous log
    launchd.stdout.log            LaunchAgent stdout
    launchd.stderr.log            LaunchAgent stderr

~/.config/raid-integrity-monitor/
    config.json                   Your configuration

~/bin/
    raid-integrity-monitor             Main binary
    raid-integrity-monitor-notify.app/ Notification helper app bundle

~/Library/LaunchAgents/
    com.airic-lenz.raid-integrity-monitor.plist
```

View recent log activity:

```sh
tail -f ~/.local/share/raid-integrity-monitor/raid-integrity-monitor.log
```

Inspect the database directly:

```sh
sqlite3 ~/.local/share/raid-integrity-monitor/manifest.db
sqlite> SELECT status, count(*) FROM files GROUP BY status;
sqlite> SELECT * FROM scans ORDER BY started_at DESC LIMIT 5;
sqlite> SELECT * FROM events WHERE event_type = 'file_corrupted';
```

---

## Manual LaunchAgent control

**Pause monitoring:**
```sh
launchctl unload ~/Library/LaunchAgents/com.airic-lenz.raid-integrity-monitor.plist
```

**Resume monitoring:**
```sh
launchctl load ~/Library/LaunchAgents/com.airic-lenz.raid-integrity-monitor.plist
```

**Run a scan immediately** (outside the schedule):
```sh
raid-integrity-monitor --mode scan
```

---

## Troubleshooting

### Notifications appear in Notification Centre but don't pop out

Open **System Settings → Notifications → RAID Integrity Monitor** and set **Alert Style** to **Alerts**. Banners auto-dismiss; Alerts stay until dismissed.

### Notifications not appearing at all

1. Run `raid-integrity-monitor --mode test` — check for errors
2. Confirm Allow Notifications is on: **System Settings → Notifications → RAID Integrity Monitor**
3. Check the LaunchAgent is loaded: `launchctl list | grep raid-integrity-monitor`
4. Check for errors: `cat ~/.local/share/raid-integrity-monitor/launchd.stderr.log`

### Reset notification permissions

If you reinstalled and notifications stopped working:

```sh
tccutil reset UserNotifications com.airic-lenz.raid-integrity-monitor
raid-integrity-monitor --mode test
```

Click **Allow** when macOS prompts, then re-set the alert style to **Alerts**.

### Scan is not finding files I expect

Check your exclusion patterns: patterns in `directoryPatterns` prune entire directory subtrees. Verify a path isn't inadvertently excluded by temporarily setting `"level": "debug"` in logging and re-running a `scan-files`.

### SMART shows "unknown" for all disks

Most USB enclosures do not expose SMART data through the USB bridge. This is expected and not a fault. Verify with:

```sh
diskutil info /dev/diskN | grep SMART
```

If it shows `Not Supported`, your enclosure does not support SMART passthrough. Leave `memberDisks` empty.

### Corruption alert for a file I know is fine

If a file is flagged as corrupted but you are confident it is intact (e.g. it was intentionally modified outside normal operation), you can reset its status directly:

```sh
sqlite3 ~/.local/share/raid-integrity-monitor/manifest.db \
  "UPDATE files SET status='ok', hash='$(shasum -a 256 /path/to/file | cut -d' ' -f1)', last_verified=unixepoch() WHERE path='/path/to/file'"
```

Then run `raid-integrity-monitor --mode scan-files` to re-verify.

---

## Limitations

- Monitors **Apple Software RAID** only. Does not support hardware RAID controllers or SoftRAID.
- Detects corruption but does not repair it — restoration requires a backup.
- No real-time detection. Corruption is found on the next scheduled scan (within 30 days by default).
- Lightroom catalogs (`.lrcat`) that are open in Lightroom may produce inconsistent hashes. This is mitigated by only re-hashing on mtime change — if Lightroom updates the mtime on save, the new hash is stored correctly. If it doesn't, a false corruption alert is possible while the file is locked.
