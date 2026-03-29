# CLAUDE.md — RAID Integrity Monitor

## Repo layout

```
RAID Monitor/
├── IntegrityMonitor/            Swift SPM project (v2 — active development)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── CBLAKE3/             Vendored BLAKE3 C reference (CC0/Apache 2.0)
│   │   ├── IntegrityMonitor/    Library target — all business logic
│   │   └── IntegrityMonitorCLI/ Executable target — main.swift only
│   ├── NotifyHelper/            Notification helper executable target
│   └── Tests/IntegrityMonitorTests/
└── CLAUDE.md
```

## Build and test

```sh
cd IntegrityMonitor

# Build (works with Command Line Tools or Xcode)
swift build

# Release build (what install.sh uses)
swift build -c release

# Run tests — requires Xcode (not just CLT) for XCTest framework
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Run the binary
.build/debug/raid-integrity-monitor --help
```

## Architecture decisions

### Library + thin CLI wrapper
`Sources/IntegrityMonitor/` is a `.target` (library), not `.executableTarget`. The executable entry point lives in `Sources/IntegrityMonitorCLI/main.swift`. This is required because SPM test targets cannot depend on executable targets — only library targets. Do not merge these two directories.

### No external dependencies
The only non-Apple imports are `sqlite3` (system-bundled), `CryptoKit` (Apple SDK), and the vendored BLAKE3 C reference implementation (`Sources/CBLAKE3/`). Do not add SwiftPM package dependencies. The zero-dependency requirement is intentional and must be preserved. BLAKE3 is vendored as C source files from the official [BLAKE3-team/BLAKE3](https://github.com/BLAKE3-team/BLAKE3) repository (CC0 / Apache 2.0), compiled as an SPM C target.

### Config uses decodeIfPresent everywhere
All `Config` sub-structs implement `init(from decoder:)` with `decodeIfPresent` and hardcoded fallbacks. This lets users write partial config files (e.g. only `watchPaths` and `database`). Do not switch back to synthesised Codable decoding — it requires all keys to be present in the JSON.

### HashUpgradeScanner fetches candidates before making hashers
`upgrade(from:to:)` queries the DB for records with the old algorithm before calling `HasherFactory.make`. If there are no candidates, it returns immediately without trying to create a hasher for an unsupported algorithm. Preserve this order.

### SQLiteManifestStore prepared statements
Statements are prepared once in `open()` and held as instance variables. They are NOT reprepared per call. This is the critical performance path — Phase 1 calls `record(for:)` once per file in the walk. Repreparing per-call would be catastrophically slow for large libraries.

### Worker pool pattern for Phase 2 and 3
Hashing uses `withThrowingTaskGroup` with a manual drain loop: add `maxHashThreads` tasks initially, then add one new task for each completed task via `group.next()`. This keeps exactly N tasks in-flight. Do not use a semaphore actor or `TaskGroup.addTask` for all files at once — the former risks deadlock, the latter ignores the thread limit.

### SMART via diskutil info
v2 uses `diskutil info /dev/<disk>` for SMART, not `smartctl`. This requires no brew dependency and is built into macOS. The relevant field is `SMART Status:` with values `Verified` / `Failing` / `Not Supported`.

### LaunchAgent schedule
The LaunchAgent uses `StartInterval` (default every 5 minutes, controlled by `schedule.raidCheckIntervalMinutes`). Each invocation always runs the RAID health check. File integrity scans only run when `schedule.fileScanIntervalHours` has elapsed since the last completed scan. The `--mode scheduled` (default) implements this logic.

## Module structure

| Module | Key types | Responsibility |
|---|---|---|
| `Models.swift` | `FileRecord`, `ScanResult`, `Alert`, `AppError` | Data types only — no logic |
| `Config.swift` | `Config`, `ConfigLoader` | JSON loading, path expansion, validation |
| `Logger.swift` | `Logger` | NSLock-based sync logger, size rotation |
| `RAID/RAIDScanner.swift` | `RAIDScanner`, `RAIDOutputParser` | diskutil invocation and line-by-line parser |
| `Database/ManifestStore.swift` | `ManifestStore` | Protocol — defines all DB operations |
| `Database/SQLiteManifestStore.swift` | `SQLiteManifestStore` | Raw sqlite3 C API implementation |
| `Database/MirroredManifestStore.swift` | `MirroredManifestStore` | Dual-write wrapper: primary required, replica best-effort |
| `Hashing/FileHasher.swift` | `SHA256Hasher`, `BLAKE3Hasher`, `HasherFactory` | CryptoKit + vendored BLAKE3 streaming hash, factory |
| `Scanning/ExclusionRules.swift` | `ExclusionRules` | fnmatch glob matching with FNM_CASEFOLD |
| `Scanning/FileScanner.swift` | `FileScanner` (actor) | 4-phase scan orchestration |
| `Notifications/AlertChannel.swift` | `MacOSAlertChannel`, `AlertManager` | Notification dispatch, config-driven filtering |
| `Upgrade/HashUpgradeScanner.swift` | `HashUpgradeScanner` | Hash algorithm migration with verify-before-upgrade |
| `IntegrityMonitorCLI/main.swift` | — | CLI arg parsing, dependency wiring, mode dispatch |

## SQLite schema

Three tables: `files` (one row per tracked file), `events` (append-only audit log), `scans` (run metadata). Schema is created in `SQLiteManifestStore.createSchema()`. The schema version is recorded in a `schema_version` table — increment it and add migration logic in `open()` if you change the schema.

Key indexes: `idx_files_last_verified` (Phase 3 rolling query), `idx_files_hash_algorithm` (upgrade query), `idx_files_status`, `idx_files_verify_rolling` (composite index on `(status, last_verified)` for efficient Phase 3 queries).

## Testing

Test files live in `Tests/IntegrityMonitorTests/`. All tests use `FileManager.temporaryDirectory` + a UUID subdirectory for isolation and clean up in `tearDown`.

Do not add tests that:
- Require a real RAID array (use fixture strings from `RAIDParserTests`)
- Send real notifications (use `AlertManager(channels: [], ...)`)
- Read from real watch paths (create test files in `tempDir`)

The `SQLiteManifestStoreTests` use a real on-disk SQLite database in the temp directory — not an in-memory DB. This is intentional to catch real I/O behaviour.

## Notification helper

`NotifyHelper/main.swift` is a standalone executable compiled into `raid-integrity-monitor-notify.app` by `install.sh`. It uses `NSApplication.shared.run()` — the event loop is required for `UNUserNotificationCenter` to deliver banner notifications on macOS 15+. The app exits via `NSApplication.shared.terminate(nil)` after delivery or a 10-second timeout.

`NotifyHelper/Info.plist` is excluded from the SPM target (`exclude: ["Info.plist"]` in `Package.swift`) and placed manually by `install.sh`. The `CFBundleIdentifier` must remain `com.airic-lenz.raid-integrity-monitor` — this is how macOS identifies the notification sender in System Settings.

## Install script

`install.sh` uses `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when Xcode is present (required for framework linking). The built binaries are `raid-integrity-monitor` and `NotifyHelper` (the SPM target name) — `install.sh` copies `NotifyHelper` to the app bundle as `raid-integrity-monitor-notify`.

Config merging on reinstall is done by an inline Python 3 script (present on all macOS versions). It adds top-level keys only — no deep merge. This is intentional: new nested keys must be added as top-level fields or documented as manual additions.


## Code Style

### Formatting
- Tab indentation
- Precede every function with an 80-character divider: `// ============================================================================`
- Property separators: `// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::`
- Always use `{ }` for control blocks (`if`, `foreach`, etc.), even one-liners
- Place every function parameter on a new line indented regarding the function name

### Naming
- Variables: descriptive and full words (e.g., `retrievedAccount` not `acc`)
- Methods: camelCase, verb-noun phrases (e.g., `calculateTotalAmount`)

### Quality
- Single responsibility: keep methods small — one method = one logical action
- Early exit: use guard clauses to flatten `if` nesting
- Code needs to be well structured, formatted and human-readable.
