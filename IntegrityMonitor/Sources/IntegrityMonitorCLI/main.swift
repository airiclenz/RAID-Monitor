import IntegrityMonitor
import Foundation

// ---------------------------------------------------------------------------
// MARK: - Entry point
// ---------------------------------------------------------------------------

// Run the async main and wait for it to complete synchronously.
// (Top-level await is not available without @main in SPM executables.)
let semaphore = DispatchSemaphore(value: 0)
var exitStatus: Int32 = 0

Task {
    do {
        exitStatus = try await run()
    } catch let error as AppError {
        fputs("raid-integrity-monitor: \(error.description)\n", stderr)
        exitStatus = 1
    } catch {
        fputs("raid-integrity-monitor: \(error.localizedDescription)\n", stderr)
        exitStatus = 1
    }
    semaphore.signal()
}

semaphore.wait()
exit(exitStatus)

// ---------------------------------------------------------------------------
// MARK: - Argument parsing
// ---------------------------------------------------------------------------

func parseArgs() -> (mode: String, configPath: String?, fromAlg: String?, toAlg: String?) {
    var mode = "scheduled"
    var configPath: String? = nil
    var fromAlg: String? = nil
    var toAlg: String? = nil

    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--mode":
            if i + 1 < args.count { mode = args[i + 1]; i += 2 } else { i += 1 }
        case "--config":
            if i + 1 < args.count { configPath = args[i + 1]; i += 2 } else { i += 1 }
        case "--from":
            if i + 1 < args.count { fromAlg = args[i + 1]; i += 2 } else { i += 1 }
        case "--to":
            if i + 1 < args.count { toAlg = args[i + 1]; i += 2 } else { i += 1 }
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            i += 1
        }
    }
    return (mode, configPath, fromAlg, toAlg)
}

func printUsage() {
    print("""
    raid-integrity-monitor — file and RAID integrity daemon

    Usage: raid-integrity-monitor [--mode <mode>] [options]

    Modes:
      scheduled       LaunchAgent mode: RAID check every run, file scan when due (default)
      scan            Full scan: RAID check + file integrity
      scan-files      File integrity scan only (no RAID)
      scan-raid       RAID health check only (no file scanning)
      upgrade-hash    Migrate hash algorithm (--from <alg> --to <alg>)
      verify-db       Cross-check primary vs replica database counts
      report          Print last scan summary
      test            Send test notification and verify setup
      init            Build baseline manifest (suppresses new-file alerts)

    Options:
      --config <path>   Path to config.json
                        (default: ~/.config/raid-integrity-monitor/config.json)
      --from <alg>      Source algorithm for upgrade-hash mode
      --to <alg>        Target algorithm for upgrade-hash mode
      --help            Show this help
    """)
}

// ---------------------------------------------------------------------------
// MARK: - Main dispatch
// ---------------------------------------------------------------------------

func run() async throws -> Int32 {
    let (mode, configPathArg, fromAlg, toAlg) = parseArgs()

    // Load config
    let configURL: URL
    if let path = configPathArg {
        configURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        configURL = ConfigLoader.defaultConfigURL()
    }

    let config: Config
    do {
        config = try ConfigLoader.load(from: configURL)
    } catch AppError.configNotFound(let url) {
        fputs("Config file not found: \(url.path)\n", stderr)
        fputs("Run 'raid-integrity-monitor --mode init' after creating a config file.\n", stderr)
        fputs("See ~/.config/raid-integrity-monitor/config.json.example for a template.\n", stderr)
        return 1
    }

    // Build shared dependencies
    let logger = Logger(
        path: config.logging.resolvedLogPath,
        level: Logger.Level.from(string: config.logging.level),
        maxBytes: config.logging.maxLogSizeBytes
    )

    let primaryStore = SQLiteManifestStore(path: config.database.resolvedPrimary)
    let replicaStore: SQLiteManifestStore? = config.database.resolvedReplica.map { SQLiteManifestStore(path: $0) }
    let store = MirroredManifestStore(primary: primaryStore, replica: replicaStore, logger: logger)

    let notifyBin = (("~/bin/raid-integrity-monitor-notify.app/Contents/MacOS/raid-integrity-monitor-notify" as NSString).expandingTildeInPath)
    let notifyChannel = MacOSAlertChannel(notifyBinaryPath: notifyBin, logger: logger)
    let alertManager = AlertManager(channels: [notifyChannel], config: config.notifications, logger: logger)

    // Mode dispatch
    switch mode {

    case "scheduled":
        try store.open()
        defer { store.close() }

        // Always run RAID check
        if config.raid.enabled {
            logger.info("Scheduled run: RAID health check")
            let raidScanner = RAIDScanner(config: config.raid, logger: logger)
            let (_, raidAlerts) = try raidScanner.scan()
            for alert in raidAlerts {
                alertManager.sendIfEnabled(raidAlert: alert)
                let eventType = alert.title.contains("Failed") ? ScanEvent.raidFailed : ScanEvent.raidDegraded
                try store.logEvent(ScanEvent(eventType: eventType, detail: alert.body))
            }
        }

        // Run file scan only if enough time has elapsed
        let fileScanIntervalSeconds = Double(config.schedule.fileScanIntervalHours) * 3600
        let lastScan = try store.lastScan()
        let lastFileScanTime = lastScan?.completedAt ?? .distantPast
        let elapsed = Date().timeIntervalSince(lastFileScanTime)

        if elapsed >= fileScanIntervalSeconds {
            logger.info("Scheduled run: file scan due (last completed \(Int(elapsed / 3600))h ago)")
            let hasher = try HasherFactory.make(for: config.hashAlgorithm)
            let exclusions = ExclusionRules(config: config.exclude)
            let raidScanner = RAIDScanner(config: config.raid, logger: logger)
            let scanner = FileScanner(
                config: config, store: store, hasher: hasher,
                exclusions: exclusions, alertManager: alertManager,
                raidScanner: raidScanner, logger: logger
            )
            _ = try await scanner.scan(mode: .filesOnly)
        } else {
            let nextIn = Int((fileScanIntervalSeconds - elapsed) / 3600)
            logger.info("Scheduled run: file scan not due yet (next in ~\(nextIn)h)")
        }

    case "scan":
        try store.open()
        defer { store.close() }
        let hasher = try HasherFactory.make(for: config.hashAlgorithm)
        let exclusions = ExclusionRules(config: config.exclude)
        let raidScanner = RAIDScanner(config: config.raid, logger: logger)
        let scanner = FileScanner(
            config: config, store: store, hasher: hasher,
            exclusions: exclusions, alertManager: alertManager,
            raidScanner: raidScanner, logger: logger
        )
        _ = try await scanner.scan(mode: .full)

    case "scan-files":
        try store.open()
        defer { store.close() }
        let hasher = try HasherFactory.make(for: config.hashAlgorithm)
        let exclusions = ExclusionRules(config: config.exclude)
        let raidScanner = RAIDScanner(config: config.raid, logger: logger)
        let scanner = FileScanner(
            config: config, store: store, hasher: hasher,
            exclusions: exclusions, alertManager: alertManager,
            raidScanner: raidScanner, logger: logger
        )
        _ = try await scanner.scan(mode: .filesOnly)

    case "scan-raid":
        let raidScanner = RAIDScanner(config: config.raid, logger: logger)
        let (arrays, alerts) = try raidScanner.scan()
        for array in arrays {
            print("Array: \(array.name) (\(array.uuid)) — \(array.status)")
            for member in array.members {
                print("  /dev/\(member.devNode): \(member.status), SMART: \(member.smartStatus.rawValue)")
            }
        }
        for alert in alerts {
            alertManager.sendIfEnabled(raidAlert: alert)
        }

    case "init":
        try store.open()
        defer { store.close() }
        let hasher = try HasherFactory.make(for: config.hashAlgorithm)
        let exclusions = ExclusionRules(config: config.exclude)
        let raidScanner = RAIDScanner(config: config.raid, logger: logger)
        let scanner = FileScanner(
            config: config, store: store, hasher: hasher,
            exclusions: exclusions, alertManager: alertManager,
            raidScanner: raidScanner, logger: logger
        )
        let result = try await scanner.scan(mode: .baseline)
        print("Baseline complete. \(result.filesNew + result.filesWalked) file(s) indexed. Run --mode scan on future runs.")

    case "upgrade-hash":
        guard let fromAlg = fromAlg, let toAlg = toAlg else {
            fputs("upgrade-hash requires --from <algorithm> and --to <algorithm>\n", stderr)
            return 1
        }
        try store.open()
        defer { store.close() }
        let upgrader = HashUpgradeScanner(store: store, alertManager: alertManager, logger: logger)
        let result = try await upgrader.upgrade(from: fromAlg, to: toAlg)
        print("Hash upgrade complete: upgraded=\(result.upgraded) corrupted=\(result.corrupted) skipped=\(result.skipped)")

    case "verify-db":
        try runVerifyDB(config: config, logger: logger)

    case "report":
        try store.open()
        defer { store.close() }
        if let last = try store.lastScan() {
            printScanReport(last)
        } else {
            print("No scans recorded yet. Run --mode scan or --mode init first.")
        }

    case "test":
        try runTestMode(config: config, store: store, alertManager: alertManager, logger: logger)

    default:
        fputs("Unknown mode: \(mode). Run --help for usage.\n", stderr)
        return 1
    }

    return 0
}

// ---------------------------------------------------------------------------
// MARK: - verify-db mode
// ---------------------------------------------------------------------------

func runVerifyDB(config: Config, logger: Logger) throws {
    let primaryStore = SQLiteManifestStore(path: config.database.resolvedPrimary)
    try primaryStore.open()
    defer { primaryStore.close() }

    let primaryPaths = try primaryStore.allPaths()
    let primaryScan  = try primaryStore.lastScan()

    print("Primary database: \(config.database.resolvedPrimary.path)")
    print("  Files tracked : \(primaryPaths.count)")
    print("  Last scan     : \(primaryScan.map { formatDate($0.startedAt) } ?? "none")")
    print("  Last status   : \(primaryScan.map { $0.status.rawValue } ?? "—")")

    if let replicaURL = config.database.resolvedReplica {
        let replicaStore = SQLiteManifestStore(path: replicaURL)
        do {
            try replicaStore.open()
            defer { replicaStore.close() }
            let replicaPaths = try replicaStore.allPaths()
            let replicaScan  = try replicaStore.lastScan()

            print("\nReplica database: \(replicaURL.path)")
            print("  Files tracked : \(replicaPaths.count)")
            print("  Last scan     : \(replicaScan.map { formatDate($0.startedAt) } ?? "none")")
            print("  Last status   : \(replicaScan.map { $0.status.rawValue } ?? "—")")

            let diff = primaryPaths.count - replicaPaths.count
            if diff == 0 {
                print("\n✓ Primary and replica row counts match.")
            } else {
                print("\n⚠ Row count mismatch: primary has \(abs(diff)) \(diff > 0 ? "more" : "fewer") files than replica.")
            }
        } catch {
            print("\nReplica database: \(replicaURL.path)")
            print("  ⚠ Could not open: \(error)")
        }
    } else {
        print("\nNo replica database configured.")
    }
}

// ---------------------------------------------------------------------------
// MARK: - test mode
// ---------------------------------------------------------------------------

func runTestMode(config: Config, store: ManifestStore, alertManager: AlertManager, logger: Logger) throws {
    print("RAID Integrity Monitor — pre-flight test\n")

    // 1. Config
    print("✓ Config loaded from: \(ConfigLoader.defaultConfigURL().path)")
    print("  watchPaths: \(config.watchPaths.joined(separator: ", "))")

    // 2. Database
    do {
        try store.open()
        store.close()
        print("✓ Database accessible: \(config.database.resolvedPrimary.path)")
    } catch {
        print("✗ Database error: \(error)")
    }

    // 3. Watch paths accessible
    for path in config.resolvedWatchPaths {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue {
            print("✓ Watch path accessible: \(path.path)")
        } else {
            print("✗ Watch path not accessible: \(path.path)")
        }
    }

    // 4. Test notification
    print("\nSending test notification…")
    alertManager.send(Alert(
        title: "RAID Integrity Monitor",
        subtitle: "Test notification",
        body: "Setup verified successfully. raid-integrity-monitor is ready.",
        severity: .info
    ))
    print("✓ Test notification sent (check Notification Centre if no banner appears)")
    print("\nNote: If notifications don't appear, grant Full Disk Access and Notifications")
    print("permission in System Settings → Privacy & Security.")
}

// ---------------------------------------------------------------------------
// MARK: - Report helpers
// ---------------------------------------------------------------------------

func printScanReport(_ scan: ScanResult) {
    let started = formatDate(scan.startedAt)
    let completed = scan.completedAt.map { formatDate($0) } ?? "—"
    let duration: String
    if let completed = scan.completedAt {
        let secs = Int(completed.timeIntervalSince(scan.startedAt))
        duration = "\(secs)s"
    } else {
        duration = "—"
    }

    print("""
    Last scan report
    ────────────────
    Started   : \(started)
    Completed : \(completed)
    Duration  : \(duration)
    Status    : \(scan.status.rawValue)

    Files walked    : \(scan.filesWalked)
    Files skipped   : \(scan.filesSkipped)
    Files new       : \(scan.filesNew)
    Files modified  : \(scan.filesModified)
    Files verified  : \(scan.filesVerified)
    Files corrupted : \(scan.filesCorrupted) \(scan.filesCorrupted > 0 ? "⚠" : "")
    Files missing   : \(scan.filesMissing) \(scan.filesMissing > 0 ? "⚠" : "")
    """)
}

func formatDate(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateStyle = .medium
    fmt.timeStyle = .medium
    return fmt.string(from: date)
}
