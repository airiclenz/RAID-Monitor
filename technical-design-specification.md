# Integrity Monitor — Design Specification

**Project:** Integrity Monitor
**Author:** Airic Lenz
**Version:** 1.0
**Date:** March 2026
**Status:** Initial Implementation

---

## Table of Contents

1. [Background and Motivation](#1-background-and-motivation)
2. [Problem Statement](#2-problem-statement)
3. [Goals and Non-Goals](#3-goals-and-non-goals)
4. [System Context](#4-system-context)
5. [Architecture Overview](#5-architecture-overview)
6. [Design Principles](#6-design-principles)
7. [Module Design](#7-module-design)
8. [Database Schema](#8-database-schema)
9. [Configuration](#9-configuration)
10. [Scanning Algorithm](#10-scanning-algorithm)
11. [Hash Algorithm Strategy](#11-hash-algorithm-strategy)
12. [Hash Upgrade Path](#12-hash-upgrade-path)
13. [Exclusion Rules](#13-exclusion-rules)
14. [Dual-Database Strategy](#14-dual-database-strategy)
15. [Concurrency Model](#15-concurrency-model)
16. [Operation Modes](#16-operation-modes)
17. [Notification System](#17-notification-system)
18. [RAID Health Integration](#18-raid-health-integration)
19. [Installation and Scheduling](#19-installation-and-scheduling)
20. [Known Limitations and Future Work](#20-known-limitations-and-future-work)
21. [Decision Log](#21-decision-log)

---

## 1. Background and Motivation

This project began as an evaluation of storage options for a Mac mini (M2 Pro, 32GB RAM) running macOS. The existing setup consists of an ORICO 4-bay USB-C enclosure running a macOS software RAID 1 mirror across two 3.5" HDDs.

During this evaluation, two structural gaps were identified in the existing setup:

**Gap 1 — No SMART monitoring.** The ORICO enclosure uses a USB-to-SATA bridge chip that does not pass SMART commands through to macOS. The existing [RAID Monitor](https://github.com/airiclenz/RAID-Monitor) already handles RAID degradation alerting, but drive health signals are unavailable at the OS level.

**Gap 2 — No silent corruption detection.** macOS HFS+ RAID (managed by Disk Utility) provides no checksumming. A bit flip on disk is undetectable — the mirror dutifully replicates the corrupted data to the second drive. This is the primary limitation of any non-ZFS filesystem for long-lived archival data.

The RAID Monitor (a shell script daemon run via launchd) was identified as the natural foundation to extend. This specification describes the full redesign: porting the RAID Monitor to Swift, adding file-level integrity checksumming, and providing an upgrade path to stronger hash algorithms in the future.

---

## 2. Problem Statement

The system must detect silent data corruption (bit-rot) on a macOS software RAID volume containing personal archival data — digital photos, a Lightroom library, music, movies, and software installers — without requiring a change of filesystem, OS, or hardware.

The fundamental constraint is that macOS HFS+ (and APFS) provide no per-block checksumming. Detection must therefore operate at the file level, as a userspace daemon, using periodic hash verification.

---

## 3. Goals and Non-Goals

### Goals

- Detect file-level content corruption (hash mismatch with unchanged mtime/size)
- Detect RAID array degradation and SMART failures (existing RAID Monitor capability, preserved)
- Support a configurable verification schedule — not every file every day
- Run efficiently on spinning HDDs without causing seek thrashing
- Store manifest data in two configurable locations (local + cloud-synced)
- Support future hash algorithm upgrades with a safe, verification-first migration path
- Operate entirely without subscription fees, cloud services, or external dependencies
- Integrate naturally into macOS via launchd, standard notifications, and familiar tooling

### Non-Goals

- **Not a replacement for backups.** Corruption detection finds problems; it does not fix them. Backups remain essential.
- **Not a real-time monitor.** The system uses scheduled scanning, not filesystem event interception (FSEvents). Real-time monitoring would require a kernel extension (kext), which conflicts with macOS security model constraints and Apple Silicon SIP requirements.
- **Not a block-level integrity system.** Block-level checksumming (equivalent to dm-integrity on Linux) requires kernel involvement. This is a userspace file-level tool.
- **Not a RAID replacement.** The system detects corruption but cannot self-heal without a redundant copy. It complements RAID, not replaces it.
- **Not cross-platform.** macOS-only by design. The notification system, RAID detection, and launchd integration are macOS-specific.

---

## 4. System Context

### Hardware

| Component | Specification |
|---|---|
| Host | Mac mini 2023, Apple M2 Pro, 32GB RAM |
| Enclosure | ORICO 4-bay USB-C (JBOD — drives exposed individually) |
| RAID | macOS software RAID 1 (mirror) across 2× 3.5" HDDs |
| Connection | USB-C |
| SMART access | Not available — USB bridge blocks passthrough |

### Data profile

| Category | Notes |
|---|---|
| Digital photos | Irreplaceable. Primary integrity concern. |
| Lightroom catalog (`.lrcat`) | Irreplaceable. Must be tracked. |
| Lightroom previews (`.lrdata`) | Fully regenerable. Must be excluded from scanning. |
| Music library | Important. Largely replaceable but inconvenient. |
| Movies | Large files. Important. |
| Software installers | Low priority. Replaceable. |

### Existing tooling

The existing [RAID Monitor](https://github.com/airiclenz/RAID-Monitor) is a shell script daemon managed by launchd. It monitors RAID array status via `diskutil` and sends macOS notifications via a compiled Swift notification helper when the array degrades. This project supersedes it.

---

## 5. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        launchd (daily)                          │
└─────────────────────────┬───────────────────────────────────────┘
                          │ executes
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    raid-integrity-monitor (binary)               │
│                                                                  │
│  main.swift                                                      │
│  ├── ConfigLoader        loads and validates config.json         │
│  ├── HasherFactory       creates concrete FileHasher             │
│  ├── SQLiteManifestStore opens primary database                  │
│  ├── MirroredManifestStore  wraps primary + optional replica     │
│  ├── AlertManager        routes alerts to notification channels  │
│  └── mode dispatch:                                              │
│      ├── RAIDScanner     checks diskutil RAID + SMART status     │
│      ├── FileScanner     4-phase integrity scan                  │
│      └── HashUpgradeScanner  --mode upgrade-hash                 │
│                                                                  │
│  Outputs:                                                        │
│  ├── SQLite database (primary)   ~/.local/share/...             │
│  ├── SQLite database (replica)   ~/iCloud Drive/...             │
│  ├── Log file                    ~/.local/share/...             │
│  └── macOS notifications         via notify helper app          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. Design Principles

### No external dependencies

The entire system links only against system libraries: `sqlite3` (bundled with macOS) and `CryptoKit` (Apple SDK). No Swift Package Manager dependencies are declared. This is a deliberate choice driven by the increasing supply-chain risk from dependency vulnerabilities, particularly in AI-assisted development contexts.

The consequence is slightly more verbose code (raw `sqlite3` C API rather than GRDB), accepted willingly in exchange for a stable, auditable dependency surface.

### Protocol-based abstraction everywhere

The three major subsystems — hashing, database, and notifications — are defined as Swift protocols. All concrete types are hidden behind these protocols. Module boundaries are crossed only via protocols. This means:

- Adding a new hash algorithm requires adding one struct and one `case` in `HasherFactory` — nothing else changes. SHA-256 and BLAKE3 are both implemented this way.
- Swapping raw `sqlite3` for GRDB requires replacing `SQLiteManifestStore` — nothing else changes.
- Adding email or webhook notifications requires adding one struct conforming to `AlertChannel` — nothing else changes.

### The hash upgrade path is a first-class feature

The database stores the hash algorithm name alongside every hash. An upgrade from one algorithm to another is a named operation mode (`--mode upgrade-hash`), not a migration script. Critically, the upgrade verifies the existing hash before computing the new one — a corrupted file is never silently given a "clean" new hash.

### Conservative defaults for spinning HDDs

The default configuration (`maxHashThreads: 2`) is tuned for the target hardware: a macOS software RAID 1 mirror on two spinning HDDs. Parallel reads on co-located spindles cause seek thrashing and reduce throughput. The concurrency limit is configurable precisely because the right value depends on hardware, and the user is best placed to tune it.

---

## 7. Module Design

### File structure

```
IntegrityMonitor/
├── Package.swift
├── Sources/CBLAKE3/                    Vendored BLAKE3 C reference (CC0/Apache 2.0)
│   ├── include/blake3.h
│   ├── blake3.c, blake3_portable.c
│   ├── blake3_dispatch.c, blake3_neon.c
│   └── blake3_impl.h
├── Sources/IntegrityMonitor/
│   ├── main.swift                      Entry point, CLI, dependency wiring
│   ├── Models.swift                    All value types (FileRecord, ScanResult, Alert, ...)
│   ├── Config.swift                    Config struct, ConfigLoader, path expansion
│   ├── Logger.swift                    Lightweight structured logger with rotation
│   │
│   ├── Hashing/
│   │   └── FileHasher.swift            FileHasher protocol + SHA256Hasher + BLAKE3Hasher + HasherFactory
│   │
│   ├── Database/
│   │   ├── ManifestStore.swift         ManifestStore protocol
│   │   ├── SQLiteManifestStore.swift   Concrete implementation (raw sqlite3)
│   │   └── MirroredManifestStore.swift Dual-write wrapper
│   │
│   ├── Scanning/
│   │   ├── ExclusionRules.swift        Pattern matching engine (fnmatch)
│   │   └── FileScanner.swift           4-phase scan orchestration
│   │
│   ├── RAID/
│   │   └── RAIDScanner.swift           diskutil integration, SMART checking
│   │
│   ├── Upgrade/
│   │   └── HashUpgradeScanner.swift    --mode upgrade-hash implementation
│   │
│   └── Notifications/
│       └── AlertChannel.swift          AlertChannel protocol + macOS implementation
│
├── Tests/IntegrityMonitorTests/
├── com.airic-lenz.raid-integrity-monitor.plist
├── install.sh
└── DESIGN.md
```

### Module dependency graph

```
main.swift
    ├── Config.swift
    ├── Models.swift
    ├── Logger.swift
    ├── Hashing/FileHasher.swift
    ├── Database/ManifestStore.swift
    │       └── Database/SQLiteManifestStore.swift
    │       └── Database/MirroredManifestStore.swift
    ├── Scanning/ExclusionRules.swift
    ├── Scanning/FileScanner.swift
    │       └── Hashing/FileHasher.swift
    │       └── Database/ManifestStore.swift
    ├── RAID/RAIDScanner.swift
    ├── Upgrade/HashUpgradeScanner.swift
    └── Notifications/AlertChannel.swift
```

All dependencies flow downward. No circular dependencies. `Models.swift` is a pure value layer that everything imports but nothing it imports.

---

## 8. Database Schema

Three tables. Schema version is tracked to support forward-compatible migrations.

### `files` — the manifest

The primary record for every tracked file. One row per path.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | Auto-increment |
| `path` | TEXT UNIQUE | Absolute path |
| `size` | INTEGER | Bytes |
| `mtime` | REAL | Unix timestamp |
| `hash` | TEXT | Hex-encoded digest |
| `hash_algorithm` | TEXT | `"sha256"`, `"blake3"`, etc. |
| `first_seen` | REAL | When first indexed |
| `last_verified` | REAL | When hash was last confirmed |
| `last_modified` | REAL | When a change was last detected (nullable) |
| `status` | TEXT | `ok` \| `new` \| `modified` \| `corrupted` \| `missing` |

Indexes: `last_verified` (Phase 3 rolling verification), `hash_algorithm` (upgrade scans), `status` (counts).

### `events` — append-only audit log

Never delete from this table. Complete history of all significant events.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `timestamp` | REAL | Unix timestamp |
| `event_type` | TEXT | See event types below |
| `path` | TEXT | Nullable — null for system events |
| `detail` | TEXT | JSON blob for structured context |

**Event types:** `scan_start`, `scan_complete`, `scan_interrupted`, `scan_failed`, `file_new`, `file_modified`, `file_corrupted`, `file_missing`, `file_verified`, `file_upgraded`, `raid_ok`, `raid_degraded`, `raid_failed`, `raid_unknown`, `upgrade_start`, `upgrade_complete`, `upgrade_skipped`.

### `scans` — scan run metadata

One row per scan run. Provides the data for `--mode report`.

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK | |
| `started_at` | REAL | |
| `completed_at` | REAL | Nullable |
| `files_walked` | INTEGER | |
| `files_skipped` | INTEGER | |
| `files_new` | INTEGER | |
| `files_modified` | INTEGER | |
| `files_verified` | INTEGER | |
| `files_corrupted` | INTEGER | |
| `files_missing` | INTEGER | |
| `files_upgraded` | INTEGER | |
| `status` | TEXT | `running` \| `completed` \| `interrupted` \| `failed` |

### SQLite pragmas

```sql
PRAGMA journal_mode = WAL;      -- Allows concurrent reads during writes
PRAGMA synchronous = NORMAL;    -- Safe for non-critical data; faster than FULL
PRAGMA foreign_keys = ON;
PRAGMA cache_size = -8000;      -- 8 MB page cache
```

---

## 9. Configuration

Configuration lives in `~/.config/raid-integrity-monitor/config.json`. The installer writes a default template on first install and never overwrites an existing config on reinstall.

### Key fields

```json
{
  "watchPaths": [...],
  "exclude": {
    "pathPatterns": ["*.tmp", "*.DS_Store", ...],
    "directoryPatterns": ["*.lrdata", ".Spotlight-V100", ...],
    "minSizeBytes": 0,
    "maxSizeBytes": null
  },
  "hashAlgorithm": "sha256",
  "schedule": {
    "verificationIntervalDays": 30,
    "raidCheckIntervalMinutes": 5,
    "fileScanIntervalHours": 24
  },
  "database": {
    "primary": "~/.local/share/raid-integrity-monitor/manifest.db",
    "replica": "~/Library/Mobile Documents/com~apple~CloudDocs/IntegrityMonitor/manifest.db"
  },
  "notifications": {
    "onCorruption": true,
    "onRAIDDegraded": true,
    "onRAIDUnavailable": true,
    "onVolumeUnavailable": true,
    "onMissingFile": false,
    "onScanComplete": false,
    "onScanCompleteWithIssues": true
  },
  "performance": {
    "maxHashThreads": 2,
    "dbBatchSize": 500,
    "maxVerificationsPerRun": 1000,
    "volumeThreadOverrides": null
  },
  "logging": {
    "logPath": "~/.local/share/raid-integrity-monitor/raid-integrity-monitor.log",
    "level": "info",
    "localTimestamps": true,
    "maxLogSizeBytes": 10485760
  },
  "raid": {
    "enabled": true,
    "memberDisks": []
  }
}
```

### Path expansion

All paths support `~` expansion. The `ConfigLoader` expands all paths at load time and validates that watch paths exist on disk. Database and log parent directories are created automatically if missing.

---

## 10. Scanning Algorithm

The scan runs in four sequential phases. Phases 2 and 3 are interleaved with Phase 1 — files are processed in batches as the directory walk proceeds, keeping memory usage bounded regardless of library size.

### Phase 0 — RAID health check

Runs `diskutil appleRAID list` and optionally checks SMART status via `diskutil info` on configured member disks. Results are written to the `events` table. Degraded or failed arrays trigger an immediate alert. This phase runs in seconds.

### Phase 1 — Directory triage (fast, metadata only)

Walks all configured watch paths using `FileManager.enumerator`. For each file:

1. `ExclusionRules.shouldDescend(into:)` is checked before entering any directory. A match prunes the entire subtree without opening it — critical for large directories like `*.lrdata` preview stores.
2. `ExclusionRules.shouldInclude(fileAt:size:)` is checked for individual files.
3. `mtime` and `size` are compared against the database record.

Files are bucketed into:
- **New** — not in database → queue for Phase 2 hashing
- **Modified** — `mtime` or `size` changed → queue for Phase 2 re-hashing
- **Stable** — `mtime` and `size` unchanged → candidate for Phase 3 rolling verification
- **Missing** — in database but not seen on disk → Phase 4

### Phase 2 — Hash new and modified files

Files from the new/modified bucket are hashed using a `TaskGroup` with `maxHashThreads` concurrency. Results are written to the database in batches of `dbBatchSize` inside single transactions for performance.

**Important:** For spinning HDDs, `maxHashThreads` should be 1 or 2. Parallel reads on co-located spindles cause seek thrashing. For SSDs, 4–8 is appropriate.

### Phase 3 — Rolling re-verification of stable files

Files whose `mtime` and `size` are unchanged since last scan are not necessarily intact. Bit-rot changes content without changing filesystem metadata. Phase 3 re-hashes a subset of stable files on each scan run to detect this.

The rolling window is controlled by two config values:
- `schedule.verificationIntervalDays` — files verified within this window are skipped
- `performance.maxVerificationsPerRun` — caps the number re-verified per scan run

On each scan, the database is queried for files with `last_verified < now - schedule.verificationIntervalDays`, ordered by `last_verified ASC` (least recently verified first), limited to `performance.maxVerificationsPerRun`. This distributes full re-verification across multiple scan runs, making each individual scan fast while ensuring every file is eventually re-verified.

**A hash mismatch in Phase 3 — where `mtime` and `size` are unchanged — is the primary bit-rot detection signal.** This event is logged to the `events` table, the file's status is set to `corrupted`, and an immediate alert is sent. The stored hash is deliberately NOT updated for corrupted files, preserving the last known-good hash for forensic comparison.

### Phase 4 — Missing file reconciliation

Files present in the database but not encountered during the walk are marked as `missing`. This is informational by default — intentional deletions and disappeared files are indistinguishable from this tool's perspective. The `onMissingFile` notification is disabled in the default config to avoid noise from expected deletions.

The reconciliation is fully implemented via a database set-difference algorithm. The system fetches all tracked paths from the database (`store.allPaths()`), compares them against paths seen during the current scan, and re-evaluates exclusions and mount states before marking files as missing.

---

## 11. Hash Algorithm Strategy

Two hash algorithms are supported. Both produce 256-bit (32-byte) digests and use the same streaming 4MB-chunk pattern to avoid loading large files into memory.

### SHA-256

SHA-256 is implemented via Apple's `CryptoKit` framework — a first-party, zero-dependency implementation. It is cryptographically strong, universally recognised, and appropriate for data integrity verification. On Apple Silicon, CryptoKit uses hardware SHA extensions for near-native throughput.

| | |
|---|---|
| **Advantages** | Hardware-accelerated on Apple Silicon; zero external code; universally recognised digest format |
| **Disadvantages** | Slower than BLAKE3 in pure software; single-threaded by design |

### BLAKE3

BLAKE3 is implemented via the official C reference from [BLAKE3-team/BLAKE3](https://github.com/BLAKE3-team/BLAKE3), vendored into `Sources/CBLAKE3/` as a Swift Package Manager C target. The vendored files include the ARM NEON optimisation (`blake3_neon.c`), which activates automatically on Apple Silicon via the `BLAKE3_USE_NEON=1` compile flag. The C source is dual-licensed CC0 / Apache 2.0.

| | |
|---|---|
| **Advantages** | ~2-3x faster than SHA-256 on Apple Silicon; Merkle tree design allows future parallelisation; modern algorithm with strong security properties |
| **Disadvantages** | Not a system framework — vendored C code must be reviewed and updated manually; no hardware acceleration path (NEON is software SIMD, not a dedicated crypto engine) |

### Choosing an algorithm

For most users, `blake3` is recommended for new installations due to its speed advantage. `sha256` remains the default for backward compatibility. Existing installations can migrate via:

```bash
raid-integrity-monitor --mode upgrade-hash --from sha256 --to blake3
```

### Algorithm name storage

The algorithm name (`"sha256"`, `"blake3"`, etc.) is stored in the `hash_algorithm` column of every file record. This means:

- Records from different algorithm generations coexist in the database
- Queries can filter by algorithm (`records(withAlgorithm:)`)
- The upgrade scan operates on exactly those records that need migration

---

## 12. Hash Upgrade Path

The hash upgrade is a deliberate, user-initiated operation. It is never automatic.

```bash
raid-integrity-monitor --mode upgrade-hash --from sha256 --to blake3
```

### Algorithm

For each file record with `hash_algorithm = "sha256"`:

1. Compute `sha256(file)` using the old hasher
2. Compare against the stored hash
   - **Match** → file is intact; compute `blake3(file)` with new hasher; update record
   - **Mismatch** → file is already corrupted; skip upgrade; set status to `corrupted`; alert; preserve old hash
3. Log outcome to `events` table

### Safety properties

- A corrupted file is never given a "clean" new hash. Corruption is detected and flagged before the algorithm is changed.
- If the upgrade is interrupted (power loss, etc.), it is safe to re-run — already-upgraded records have `hash_algorithm = "blake3"` and are not selected by the `--from sha256` filter.
- The `events` table records every upgrade outcome for audit purposes.

---

## 13. Exclusion Rules

Exclusions are entirely data-driven — no library, application, or vendor names are hardcoded in the source code. All exclusion knowledge lives in `config.json`.

### Two distinct mechanisms

**`pathPatterns`** — matched against the full file path and the filename. A match causes the individual file to be skipped.

**`directoryPatterns`** — matched against directory names. A match causes the entire subtree to be skipped without descending. This is important for performance: large directories (Lightroom previews, Spotlight indexes) are excluded without the filesystem ever being asked to enumerate their contents.

### Pattern matching

Patterns use `fnmatch` glob syntax with `FNM_CASEFOLD` (case-insensitive, appropriate for HFS+ which is case-insensitive by default). Supported wildcards: `*` (any sequence), `?` (any single character), `[abc]` (character class).

### Lightroom example

The correct configuration to scan the Lightroom catalog but exclude previews — without any Lightroom-specific code:

```json
"directoryPatterns": ["*.lrdata"]
```

`My Catalog.lrcat` lives in the parent directory and is scanned normally. `My Catalog Previews.lrdata` is a directory matching `*.lrdata` and its entire subtree is skipped before the directory is even opened.

---

## 14. Dual-Database Strategy

The manifest database is written to two configurable locations simultaneously.

### Rationale

- The **primary** database should be fast and local (e.g. internal SSD or a reliable path on the same machine)
- The **replica** database should be on a separately synced location — iCloud Drive, Google Drive File Stream, Dropbox, or any service that presents as a local filesystem path

This provides:
- Protection against the primary machine failing (replica is offsite/cloud)
- Protection against the replica being unavailable (primary always works)
- The manifest travels with the data if drives are moved to a new machine

### Failure model

Writes always go to both stores. The primary must succeed — a primary write failure aborts the current operation. The replica is best-effort — a replica write failure logs a warning and continues. A scan is never aborted due to a replica failure (e.g. iCloud Drive being temporarily unavailable).

Reads always come from the primary.

### Implementation

`MirroredManifestStore` wraps two `ManifestStore` instances and implements the protocol itself. The rest of the system interacts with it through the `ManifestStore` protocol and is unaware of the dual-write behaviour.

```swift
let store = MirroredManifestStore(
    primary: SQLiteManifestStore(path: config.database.resolvedPrimary),
    replica: SQLiteManifestStore(path: config.database.resolvedReplica),
    logger: logger
)
```

---

## 15. Concurrency Model

The system uses Swift structured concurrency (`async/await`, `TaskGroup`) for the hashing phases. The scan orchestrator is an `actor` to protect mutable scan state.

### HDD vs SSD concurrency

| Storage type | Recommended `maxHashThreads` | Reason |
|---|---|---|
| Single spinning HDD | 1 | Parallel reads cause seek thrashing |
| macOS RAID 1 mirror, 2× HDD | 1–2 | Both drives serve reads; limited by slowest seek |
| SSD (single) | 4–8 | Parallelism helps; no mechanical seek penalty |
| NVMe | 8+ | Very high queue depth; more threads = more throughput |

The default is 2, conservative for the target hardware (2× HDD RAID mirror).

### Database concurrency

SQLite is opened with `SQLITE_OPEN_FULLMUTEX` — all calls are serialised at the SQLite level. WAL mode allows concurrent reads alongside writes. Batch inserts are wrapped in explicit transactions (`BEGIN IMMEDIATE`) to avoid per-row commit overhead.

---

## 16. Operation Modes

| Mode | Command | Description |
|---|---|---|
| `scheduled` | `--mode scheduled` | Automatic mode (LaunchAgent default). Defers to `config.json` rules for scan vs. RAID check periodicity. |
| `scan` | `--mode scan` | RAID health check + full file integrity scan |
| `scan-files` | `--mode scan-files` | File integrity only, no RAID check |
| `scan-raid` | `--mode scan-raid` | RAID health only, no file scanning |
| `verify` | `--mode verify` | Re-hash all tracked files regardless of elapsed time |
| `upgrade-hash` | `--mode upgrade-hash --from sha256 --to blake3` | Migrate hash algorithm |
| `verify-db` | `--mode verify-db` | Cross-check primary vs replica database statistics |
| `report` | `--mode report` | Print last scan summary without scanning |
| `test` | `--mode test` | Send test notification to verify setup |

### The `scan` mode as an initializer

On first run, you should perform `--mode scan` manually to build the baseline manifest. Subsequent alerts for missing or degraded files are configured via standard notification toggles.

---

## 17. Notification System

### Protocol

```swift
protocol AlertChannel: Sendable {
    func send(_ alert: Alert) throws
}
```

Any number of `AlertChannel` conformers can be registered with `AlertManager`. The current implementation provides one: `MacOSNotificationChannel`.

### macOS implementation

Notifications are delivered via the same compiled Swift notification helper app used in the original RAID Monitor. The helper is a minimal macOS app that receives a title, subtitle, and body as command-line arguments and posts a `UNUserNotification`. This approach avoids requiring a full app bundle for the main binary.

### Alert routing

`AlertManager` applies the notification configuration to decide which alerts to send:

| Alert type | Default | Config key |
|---|---|---|
| File corruption detected | Always sent | (not configurable — never silenced) |
| RAID array degraded/failed | On | `onRAIDDegraded` |
| File missing | Off | `onMissingFile` |
| Scan complete (all ok) | Off | `onScanComplete` |
| Scan complete with issues | On | `onScanCompleteWithIssues` |

Corruption alerts (`Alert.severity == .critical`) are always sent regardless of configuration. They cannot be silenced.

---

## 18. RAID Health Integration

The `RAIDScanner` module ports the core logic of the original shell-based RAID Monitor to Swift. It runs `diskutil appleRAID list` and parses the output for status indicators.

### SMART checking

When `raid.memberDisks` is populated in config (e.g. `["disk2", "disk3"]`), the scanner additionally checks SMART status via `diskutil info <disk>`. If SMART reports anything other than `Verified`, the RAID state is reported as degraded.

This partially addresses the original SMART gap. Note that this only works when the drives are accessible via `diskutil` — it does not bypass USB bridge SMART blocking. For a NAS solution (future direction), Linux `smartmontools` with `-d sat` provides full SMART access.

### State machine

```
ok → (member disk removed)   → degraded → alert
ok → (member disk failed)    → failed   → alert
ok → (SMART reports failure) → degraded → alert
```

All state transitions are logged to the `events` table.

---

## 19. Installation and Scheduling

### Build and install

```bash
cd IntegrityMonitor
./install.sh
```

The installer:
1. Builds the release binary via `swift build -c release`
2. Installs the binary to `~/bin/raid-integrity-monitor`
3. Writes a default config template to `~/.config/raid-integrity-monitor/config.json` (first install only)
4. Installs and loads the LaunchAgent plist to `~/Library/LaunchAgents/`
5. Sends a test notification to verify the notification stack

### launchd scheduling

The LaunchAgent runs the scanner periodically via `StartInterval`. By default, this is every 3600 seconds (1 hour) but earlier configs might have used lower intervals. The exact frequency of heavy disk scans vs RAID checks is driven by the `scheduled` mode and the limits assigned within `config.json` (`schedule.raidCheckIntervalMinutes` and `schedule.fileScanIntervalHours`).

`RunAtLoad` is `false` — the scanner does not run immediately on login, only on schedule. To run manually at any time:

```bash
~/bin/raid-integrity-monitor --mode scan
```

### macOS permissions

The binary requires **Full Disk Access** to scan all watch paths. This must be granted manually in:

> System Settings → Privacy & Security → Full Disk Access → add `raid-integrity-monitor`

The installer prints a reminder. Without this permission, the scanner will silently skip directories it cannot read.

---

## 20. Known Limitations and Future Work

### No real-time detection

The system detects corruption on the next scheduled scan run, not immediately when it occurs. On a daily schedule with a 30-day rolling verification window, a corrupted file could go undetected for up to 30 days. This is acceptable for archival data where files change infrequently. A shorter `verificationIntervalDays` or more frequent `launchd` scheduling can reduce this window.

### USB SMART passthrough gap

The original SMART gap (USB bridge blocking SMART passthrough) is not resolved by this system. The `raid.memberDisks` SMART check only works if `diskutil` can access SMART data — which it cannot through the ORICO enclosure's USB bridge. Moving to a proper Linux NAS (with native SATA connections) would resolve this completely.

### No self-healing

The system detects corruption but cannot fix it. Recovery requires a backup. This is by design — self-healing requires redundancy awareness (ZFS mirror logic) that is outside scope for a userspace file-integrity daemon.

### Lightroom catalog file locking

Hashing the Lightroom catalog (`.lrcat`) while Lightroom has it open may produce inconsistent results. Lightroom uses SQLite internally and WAL mode — an in-progress write during hashing could produce a hash that doesn't match on the next verification. Mitigation: the mtime-gating in Phase 1 means the catalog is only re-hashed when Lightroom has written to it. Consider excluding the catalog from Phase 3 rolling verification (hash only when changed, never re-verify without mtime change) as a future config option.

---

## 21. Decision Log

A record of significant design decisions and the reasoning behind them.

| Decision | Alternatives considered | Reasoning |
|---|---|---|
| SHA-256 and BLAKE3 as dual algorithm options | Single algorithm only | SHA-256 via CryptoKit provides hardware acceleration and zero external code; BLAKE3 via vendored C reference provides ~2-3x speed improvement. Both produce 256-bit digests. Protocol + factory pattern makes adding algorithms a single-file change. BLAKE3 C source is vendored (not an external dependency) to preserve the zero-dependency requirement. |
| Raw sqlite3 C API, not GRDB | GRDB (cleaner Swift API, external dependency) | No external dependencies. GRDB is swappable by replacing `SQLiteManifestStore` — one file. |
| Scheduled scan, not FSEvents real-time | FSEvents daemon | FSEvents cannot capture kernel-level writes (journaling, Spotlight). Real-time would require a kext, conflicting with SIP on Apple Silicon. Scheduled scan is simpler, auditable, and sufficient for archival data. |
| File-level checksumming, not block-level | dm-integrity equivalent (kernel module) | Kernel modules on macOS require disabling SIP — a security regression. File-level detection catches the vast majority of real-world bit-rot. |
| `directoryPatterns` as a separate exclusion mechanism | Single pattern list for files and directories | Directories must be excluded before descending to avoid enumerating their contents. A unified pattern list that matches both files and directory names cannot efficiently prune subtrees. |
| `maxHashThreads` as a config value, not auto-detected | IOKit-based HDD/SSD detection | Auto-detection adds complexity; the user knows their hardware. Config value is explicit, auditable, and works correctly first time if the user follows the documented recommendations. |
| Dual database (primary + replica) | Single database; cloud sync via rsync | The dual-write approach keeps the replica in sync as a side-effect of normal operation — no separate sync job. The `MirroredManifestStore` pattern makes this transparent to all callers. |
| `init` mode for first run | Suppress alerts for N days after install | `init` is explicit and deterministic. Time-based suppression has edge cases (clock changes, interrupted runs). |
| Preserve corrupted file's old hash | Update hash to reflect current (corrupted) state | The old hash is the last known-good state and has forensic value. Overwriting it would lose the ability to check whether the corruption changes over time. |
| Upgrade scan verifies old hash before computing new | Compute new hash directly | Silent re-hashing of already-corrupted files would give them a "clean" new hash, masking existing corruption. Verify-before-upgrade is a hard safety requirement. |
| Swift SPM project | Xcode project; shell scripts | SPM is clean for CLI tools with no UI. Fits naturally with VS Code + Claude Code development workflow. No Xcode required to build. |
| Protocol-based abstraction for all major subsystems | Concrete types throughout | Allows swapping implementations (hash algorithm, database, notification channel) by changing one file. Reduces coupling. Makes unit testing possible without real databases or filesystems. |
