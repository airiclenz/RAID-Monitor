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

// ============================================================================
func parseArgs() -> (
	mode: String,
	configPath: String?,
	fromAlg: String?,
	toAlg: String?
) {
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

// ============================================================================
func printUsage() {
	print("""
	raid-integrity-monitor — file and RAID integrity daemon

	Usage: raid-integrity-monitor [--mode <mode>] [options]

	Modes:
	  scheduled		  LaunchAgent mode: RAID check every run, file scan when due (default)
	  scan			  Full scan: RAID check + file integrity
	  scan-files	  File integrity scan only (no RAID)
	  scan-raid		  RAID health check only (no file scanning)
	  verify		  Re-verify all tracked files against stored hashes
	  upgrade-hash	  Migrate hash algorithm (--from <alg> --to <alg>)
	  verify-db		  Cross-check primary vs replica database counts
	  report		  Print last scan summary
	  test			  Send test notification and verify setup

	Options:
	  --config <path>	Path to config.json
						(default: ~/.config/raid-integrity-monitor/config.json)
	  --from <alg>		Source algorithm for upgrade-hash mode
	  --to <alg>		Target algorithm for upgrade-hash mode
	  --help			Show this help
	""")
}

// ---------------------------------------------------------------------------
// MARK: - Main dispatch
// ---------------------------------------------------------------------------

// ============================================================================
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
		fputs("Run 'raid-integrity-monitor --mode scan' after creating a config file.\n", stderr)
		fputs("See ~/.config/raid-integrity-monitor/config.json.example for a template.\n", stderr)
		return 1
	}

	// Acquire process lock for modes that modify state
	let exclusiveModes: Set<String> = ["scheduled", "scan", "scan-files", "scan-raid", "verify", "upgrade-hash"]
	let processLock = ProcessLock(directory: configURL.deletingLastPathComponent())
	if exclusiveModes.contains(mode) {
		if let reason = processLock.tryAcquire() {
			fputs("\(reason). Exiting.\n", stderr)
			return 1
		}
	}
	defer { processLock.release() }

	// Build shared dependencies
	let logger = Logger(
		path: config.logging.resolvedLogPath,
		level: Logger.Level.from(string: config.logging.level),
		maxBytes: config.logging.maxLogSizeBytes,
		localTimestamps: config.logging.localTimestamps
	)

	let primaryStore = SQLiteManifestStore(
		path: config.database.resolvedPrimary
	)
	let replicaStore: SQLiteManifestStore? = config.database.resolvedReplica.map {
		SQLiteManifestStore(path: $0)
	}
	let store = MirroredManifestStore(
		primary: primaryStore,
		replica: replicaStore,
		logger: logger
	)

	let notifyBin = (("~/bin/raid-integrity-monitor-notify.app/Contents/MacOS/raid-integrity-monitor-notify" as NSString).expandingTildeInPath)
	let notifyChannel = MacOSAlertChannel(
		notifyBinaryPath: notifyBin,
		logger: logger
	)
	let alertManager = AlertManager(
		channels: [notifyChannel],
		config: config.notifications,
		logger: logger
	)

	// In-place progress display for interactive terminals
	let isTerminal = isatty(STDERR_FILENO) != 0
	nonisolated(unsafe) var progressActive = false
	let progressHandler: FileScanner.ProgressHandler = { message in
		if isTerminal {
			if message.isEmpty {
				// Empty message = end of progress block; clear line only if progress was shown
				if progressActive {
					fputs("\r\u{1B}[K\n", stderr)
					progressActive = false
				}
			} else {
				progressActive = true
				fputs("\r\(message)\u{1B}[K", stderr)
			}
		}
	}
	let clearProgress = {
		if isTerminal && progressActive {
			fputs("\r\u{1B}[K\n", stderr)
			progressActive = false
		}
	}

	// Mode dispatch
	switch mode {

	case "scheduled":
		try store.open()
		defer { store.close() }

		// Always run RAID check — only alert on state transitions
		if config.raid.enabled {
			logger.info("\(Logger.c("Scheduled run:", .boldCyan)) RAID health check")
			let raidScanner = RAIDScanner(
				config: config.raid,
				logger: logger
			)
			let (_, raidAlerts) = try raidScanner.scan()

			// Derive current RAID state from scan results
			let currentState: String
			if raidAlerts.isEmpty {
				currentState = ScanEvent.raidOnline
			} else if raidAlerts.contains(where: { $0.title.contains("Unavailable") }) {
				currentState = ScanEvent.raidDisappeared
			} else if raidAlerts.contains(where: { $0.title.contains("Failed") }) {
				currentState = ScanEvent.raidFailed
			} else if raidAlerts.contains(where: { $0.title.contains("SMART") }) {
				currentState = ScanEvent.smartFailed
			} else {
				currentState = ScanEvent.raidDegraded
			}

			// Compare with previous state (assume online if no prior event)
			let previousEvent = try store.lastRaidEvent()
			let previousState = previousEvent?.eventType ?? ScanEvent.raidOnline

			if currentState != previousState {
				if currentState == ScanEvent.raidOnline {
					// Recovery: RAID was unhealthy, now healthy
					let recoveryAlert = Alert(
						title: "RAID Array Recovered",
						subtitle: "All arrays online",
						body: "RAID health restored. Previous state: \(previousState).",
						severity: .info
					)
					alertManager.send(recoveryAlert)
					try store.logEvent(ScanEvent(
						eventType: ScanEvent.raidOnline,
						detail: "Recovered from \(previousState)"
					))
				} else {
					// Unhealthy transition — dispatch alerts
					for alert in raidAlerts {
						if alert.title.contains("Unavailable") {
							alertManager.sendIfEnabled(raidUnavailable: alert)
						} else {
							alertManager.sendIfEnabled(raidAlert: alert)
						}
					}
					try store.logEvent(ScanEvent(
						eventType: currentState,
						detail: raidAlerts.first?.body
					))
				}
			} else {
				logger.info("RAID state unchanged (\(Logger.c(currentState, .white))) — no alert sent")
			}
		}

		// Run file scan only if enough time has elapsed
		let fileScanIntervalSeconds = Double(config.schedule.fileScanIntervalHours) * 3600
		let lastScan = try store.lastScan()
		let lastFileScanTime = lastScan?.completedAt ?? .distantPast
		let elapsed = Date().timeIntervalSince(lastFileScanTime)

		if elapsed >= fileScanIntervalSeconds {
			logger.info("\(Logger.c("Scheduled run:", .boldCyan)) file scan due (last completed \(Logger.c("\(Int(elapsed / 3600))h", .boldWhite)) ago)")
			let hasher = try HasherFactory.make(for: config.hashAlgorithm)
			let exclusions = ExclusionRules(config: config.exclude)
			let raidScanner = RAIDScanner(
				config: config.raid,
				logger: logger
			)
			let scanner = FileScanner(
				config: config,
				store: store,
				hasher: hasher,
				exclusions: exclusions,
				alertManager: alertManager,
				raidScanner: raidScanner,
				logger: logger
			)
			_ = try await scanner.scan(mode: .filesOnly)
		} else {
			let nextIn = Int((fileScanIntervalSeconds - elapsed) / 3600)
			logger.info("\(Logger.c("Scheduled run:", .boldCyan)) file scan not due yet (next in \(Logger.c("~\(nextIn)h", .boldWhite)))")
		}

	case "scan":
		try store.open()
		defer { store.close() }
		let hasher = try HasherFactory.make(for: config.hashAlgorithm)
		let exclusions = ExclusionRules(config: config.exclude)
		let raidScanner = RAIDScanner(
			config: config.raid,
			logger: logger
		)
		let scanner = FileScanner(
			config: config,
			store: store,
			hasher: hasher,
			exclusions: exclusions,
			alertManager: alertManager,
			raidScanner: raidScanner,
			logger: logger,
			onProgress: progressHandler
		)
		let result = try await scanner.scan(mode: .full)
		clearProgress()
		print("Scan complete. \(result.filesWalked) file(s) checked, \(result.filesNew) new, \(result.filesModified) modified, \(result.filesCorrupted) corrupted, \(result.filesMissing) missing.")

	case "scan-files":
		try store.open()
		defer { store.close() }
		let hasher = try HasherFactory.make(for: config.hashAlgorithm)
		let exclusions = ExclusionRules(config: config.exclude)
		let raidScanner = RAIDScanner(
			config: config.raid,
			logger: logger
		)
		let scanner = FileScanner(
			config: config,
			store: store,
			hasher: hasher,
			exclusions: exclusions,
			alertManager: alertManager,
			raidScanner: raidScanner,
			logger: logger,
			onProgress: progressHandler
		)
		_ = try await scanner.scan(mode: .filesOnly)
		clearProgress()

	case "scan-raid":
		let raidScanner = RAIDScanner(
			config: config.raid,
			logger: logger
		)
		let (arrays, alerts) = try raidScanner.scan()
		for array in arrays {
			print("Array: \(array.name) (\(array.uuid)) — \(array.status)")
			for member in array.members {
				print("  /dev/\(member.devNode): \(member.status), SMART: \(member.smartStatus.rawValue)")
			}
		}
		for alert in alerts {
			if alert.title.contains("Unavailable") {
				alertManager.sendIfEnabled(raidUnavailable: alert)
			} else {
				alertManager.sendIfEnabled(raidAlert: alert)
			}
		}

	case "verify":
		try store.open()
		defer { store.close() }
		let hasher = try HasherFactory.make(for: config.hashAlgorithm)
		let exclusions = ExclusionRules(config: config.exclude)
		let raidScanner = RAIDScanner(
			config: config.raid,
			logger: logger
		)
		let scanner = FileScanner(
			config: config,
			store: store,
			hasher: hasher,
			exclusions: exclusions,
			alertManager: alertManager,
			raidScanner: raidScanner,
			logger: logger,
			onProgress: progressHandler
		)
		let result = try await scanner.scan(mode: .verifyAll)
		clearProgress()
		print("Verification complete. \(result.filesVerified) file(s) verified, \(result.filesCorrupted) corrupted.")

	case "upgrade-hash":
		guard let fromAlg = fromAlg, let toAlg = toAlg else {
			fputs("upgrade-hash requires --from <algorithm> and --to <algorithm>\n", stderr)
			return 1
		}
		try store.open()
		defer { store.close() }
		let upgrader = HashUpgradeScanner(
			store: store,
			config: config,
			alertManager: alertManager,
			logger: logger,
			onProgress: progressHandler
		)
		let result = try await upgrader.upgrade(
			from: fromAlg,
			to: toAlg
		)
		clearProgress()
		print("Hash upgrade complete: upgraded=\(result.upgraded) corrupted=\(result.corrupted) skipped=\(result.skipped)")

	case "verify-db":
		try runVerifyDB(
			config: config,
			logger: logger
		)

	case "report":
		try store.open()
		defer { store.close() }
		if let last = try store.lastScan() {
			printScanReport(last)
		} else {
			print("No scans recorded yet. Run --mode scan first.")
		}

	case "test":
		try runTestMode(
			config: config,
			store: store,
			alertManager: alertManager,
			logger: logger
		)

	default:
		fputs("Unknown mode: \(mode). Run --help for usage.\n", stderr)
		return 1
	}

	return 0
}

// ---------------------------------------------------------------------------
// MARK: - verify-db mode
// ---------------------------------------------------------------------------

// ============================================================================
func runVerifyDB(
	config: Config,
	logger: Logger
) throws {
	let primaryStore = SQLiteManifestStore(
		path: config.database.resolvedPrimary
	)
	try primaryStore.open()
	defer { primaryStore.close() }

	let primaryPaths = try primaryStore.allPaths()
	let primaryScan = try primaryStore.lastScan()

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
			let replicaScan = try replicaStore.lastScan()

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

// ============================================================================
func runTestMode(
	config: Config,
	store: ManifestStore,
	alertManager: AlertManager,
	logger: Logger
) throws {
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
	// Give the notification helper time to deliver the banner before we exit.
	// The helper runs as a separate process; without this pause the main
	// process can exit before the notification is shown.
	Thread.sleep(forTimeInterval: 3)
	print("✓ Test notification sent (check Notification Centre if no banner appears)")
	print("\nNote: If notifications don't appear, grant Full Disk Access and Notifications")
	print("permission in System Settings → Privacy & Security.")
}

// ---------------------------------------------------------------------------
// MARK: - Report helpers
// ---------------------------------------------------------------------------

// ============================================================================
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
	─────────────────────────────
	Started         : \(started)
	Completed       : \(completed)
	Duration        : \(duration)
	Status          : \(scan.status.rawValue)

	Files walked    : \(scan.filesWalked)
	Files skipped   : \(scan.filesSkipped)
	Files new       : \(scan.filesNew)
	Files modified  : \(scan.filesModified)
	Files verified  : \(scan.filesVerified)
	Files corrupted : \(scan.filesCorrupted) \(scan.filesCorrupted > 0 ? "⚠" : "")
	Files missing   : \(scan.filesMissing) \(scan.filesMissing > 0 ? "⚠" : "")
	""")
}

// ============================================================================
func formatDate(_ date: Date) -> String {
	let formatter = DateFormatter()
	formatter.dateStyle = .medium
	formatter.timeStyle = .medium
	return formatter.string(from: date)
}
