import Foundation

// ---------------------------------------------------------------------------
// MARK: - FileScanner
//
// Orchestrates the 4-phase file integrity scan:
//
//	 Phase 0 — RAID health check (optional, via RAIDScanner)
//	 Phase 1 — Directory walk + triage (metadata only)
//			   Classifies each file as: new / modified / stable / missing
//	 Phase 2 — Hash new and modified files
//			   Uses a worker-pool pattern to respect maxHashThreads
//	 Phase 3 — Rolling re-verification of stable files
//			   Gradually re-hashes all files based on verificationIntervalDays
//	 Phase 4 — Missing file reconciliation
//			   Compares walked paths against the full manifest
//
// FileScanner is an actor so all scan operations are serialised and the
// ManifestStore is never accessed from multiple tasks concurrently.
// ---------------------------------------------------------------------------

public actor FileScanner {

	public enum ScanMode {
		/// Full scan: Phase 0 (RAID) + Phases 1–4 (file integrity)
		case full
		/// File integrity only: Phases 1–4 (no RAID check)
		case filesOnly
		/// Re-verify all tracked files against stored hashes (no walk, no missing-file check)
		case verifyAll
	}

	/// Called with a progress string to display (e.g. "Phase 1: 1234 files walked").
	/// The caller is responsible for in-place terminal updates (\r) if desired.
	public typealias ProgressHandler = @Sendable (String) -> Void

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	private let config: Config
	private let store: ManifestStore
	private let hasher: any FileHasher
	private let exclusions: ExclusionRules
	private let alertManager: AlertManager
	private let raidScanner: RAIDScanner
	private let logger: Logger
	private let onProgress: ProgressHandler?

	/// Files above this size get per-file byte progress in the progress line.
	private let largeFileThreshold: Int64 = 30 * 1024 * 1024

	/// Per-volume concurrency info, keyed by device ID.
	private let volumeMap: [dev_t: VolumeInfo]

	/// Per-volume semaphores that gate concurrent hash reads.
	private let volumeSemaphores: [dev_t: VolumeSemaphore]

	// ============================================================================
	public init(
		config: Config,
		store: ManifestStore,
		hasher: any FileHasher,
		exclusions: ExclusionRules,
		alertManager: AlertManager,
		raidScanner: RAIDScanner,
		logger: Logger,
		onProgress: ProgressHandler? = nil
	) {
		self.config = config
		self.store = store
		self.hasher = hasher
		self.exclusions = exclusions
		self.alertManager = alertManager
		self.raidScanner = raidScanner
		self.logger = logger
		self.onProgress = onProgress

		self.volumeMap = VolumeDetector.detectVolumes(
			for: config.resolvedWatchPaths,
			globalMaxThreads: config.performance.maxHashThreads,
			overrides: config.performance.volumeThreadOverrides ?? [:],
			logger: logger
		)

		var semaphores: [dev_t: VolumeSemaphore] = [:]
		for (devID, info) in self.volumeMap {
			semaphores[devID] = VolumeSemaphore(limit: info.maxHashThreads)
		}
		self.volumeSemaphores = semaphores
	}

	// ============================================================================
	/// Return the semaphore for a file's volume, or nil if unresolved.
	private func volumeSemaphore(for path: String) -> VolumeSemaphore? {
		let devID = VolumeDetector.deviceID(for: path)
		return volumeSemaphores[devID]
	}

	// ============================================================================
	/// Total hash concurrency across all volumes.
	private var totalHashThreads: Int {
		let sum = volumeMap.values.reduce(0) { $0 + $1.maxHashThreads }
		return sum > 0 ? sum : config.performance.maxHashThreads
	}

	// MARK: - Public entry point

	// ============================================================================
	public func scan(mode: ScanMode = .full) async throws -> ScanResult {
		var result = ScanResult(startedAt: Date())
		result.id = try store.insertScan(result)

		try store.logEvent(ScanEvent(eventType: ScanEvent.scanStart))
		logger.info("\(Logger.c("=== Scan started", .boldGreen)) (mode: \(Logger.c("\(mode)", .boldWhite)))\(Logger.c(" ===", .boldGreen))")

		do {
			if mode == .verifyAll {
				// Verify-all: re-hash every tracked file, no walk or missing-file check
				result = try await runVerifyAll(result: result)
			} else {
				// Phase 0: RAID health check
				if mode != .filesOnly && config.raid.enabled {
					try await runRAIDPhase()
				}

				// Phases 1–4: file integrity
				result = try await runFilePhases(result: result)
			}
			result.status = .completed

		} catch {
			result.status = .interrupted
			result.completedAt = Date()
			try? store.updateScan(result)
			try store.logEvent(ScanEvent(
				eventType: "scan_error",
				detail: error.localizedDescription
			))
			logger.error("\(Logger.c("Scan interrupted:", .boldRed)) \(error)")
			throw error
		}

		result.completedAt = Date()
		try store.updateScan(result)
		try store.logEvent(ScanEvent(
			eventType: ScanEvent.scanComplete,
			detail: scanSummaryJSON(result)
		))

		let hasIssues = result.filesCorrupted > 0 || result.filesMissing > 0
		alertManager.sendIfEnabled(
			scanComplete: Alert(
				title: "RAID Integrity Scan Complete",
				subtitle: hasIssues ? "Issues found" : "No issues",
				body: scanSummaryText(result),
				severity: hasIssues ? .warning : .info
			),
			hasIssues: hasIssues
		)

		logger.info("\(Logger.c("=== Scan complete:", .boldGreen)) \(scanSummaryText(result))\(Logger.c(" ===", .boldGreen))")
		return result
	}

	// MARK: - Phase 0: RAID

	// ============================================================================
	private func runRAIDPhase() async throws {
		logger.info("\(Logger.c("Phase 0:", .boldCyan)) RAID health check")
		let (_, alerts) = try raidScanner.scan()
		for alert in alerts {
			if alert.title.contains("Unavailable") {
				alertManager.sendIfEnabled(raidUnavailable: alert)
				try store.logEvent(ScanEvent(
					eventType: ScanEvent.raidDisappeared,
					detail: alert.body
				))
			} else {
				alertManager.sendIfEnabled(raidAlert: alert)
				let eventType = alert.title.contains("Failed") ? ScanEvent.raidFailed : ScanEvent.raidDegraded
				try store.logEvent(ScanEvent(
					eventType: eventType,
					detail: alert.body
				))
			}
		}
	}

	// MARK: - Phases 1–4: File integrity

	// ============================================================================
	private func runFilePhases(result: ScanResult) async throws -> ScanResult {
		var result = result

		// Pre-scan: sync primary → replica (no-op if no replica configured)
		logger.info("Syncing replica database \(Logger.c("(if configured)", .dim))")
		try store.syncReplica()

		// Phase 1: directory walk + triage
		logger.info("\(Logger.c("Phase 1:", .boldCyan)) Directory walk and triage")
		let (toHash, pathsSeen, walkedPrefixes) = try runPhase1(result: &result)
		onProgress?("")	 // end progress block

		// Phase 2: hash new/modified files
		logger.info("\(Logger.c("Phase 2:", .boldCyan)) Hashing \(Logger.c("\(toHash.count)", .boldWhite)) new/modified file(s)")
		try await runPhase2(toHash: toHash, result: &result)
		onProgress?("")	 // end progress block

		// Phase 3: rolling re-verification
		let verificationCutoff = Date().addingTimeInterval(-Double(config.schedule.verificationIntervalDays) * 86400)
		let toVerify = try store.filesToVerify(
			before: verificationCutoff,
			limit: config.performance.maxVerificationsPerRun
		)
logger.info("\(Logger.c("Phase 3:", .boldCyan)) Re-verifying \(Logger.c("\(toVerify.count)", .boldWhite)) file(s)")
		try await runPhase3(toVerify: toVerify, result: &result)
		onProgress?("")  // end progress block

		// Phase 4: missing file reconciliation
		logger.info("\(Logger.c("Phase 4:", .boldCyan)) Missing file reconciliation")
		try runPhase4(pathsSeen: pathsSeen, walkedPrefixes: walkedPrefixes, result: &result)

		return result
	}

	// MARK: - Verify-all mode

	// ============================================================================
	private func runVerifyAll(result: ScanResult) async throws -> ScanResult {
		var result = result

		let toVerify = try store.allFilesToVerify()
		logger.info("\(Logger.c("Verify-all:", .boldCyan)) re-verifying \(Logger.c("\(toVerify.count)", .boldWhite)) file(s)")
		try await runPhase3(toVerify: toVerify, result: &result)
		onProgress?("")	 // end progress block

		return result
	}

	// MARK: - Phase 1: Walk

	// ============================================================================
	private func runPhase1(result: inout ScanResult) throws -> (toHash: [(URL, FileRecord?)], pathsSeen: Set<String>, walkedPrefixes: Set<String>) {
		var toHash: [(URL, FileRecord?)] = []
		var pathsSeen = Set<String>()
		var walkedPrefixes = Set<String>()

		for watchURL in config.resolvedWatchPaths {
			// Verify the watch path is accessible before enumerating.
			// If a volume is unmounted, we must skip it entirely to avoid
			// Phase 4 marking every file on that volume as missing.
			var isDir: ObjCBool = false
			guard FileManager.default.fileExists(
				atPath: watchURL.path,
				isDirectory: &isDir
			), isDir.boolValue else {
				logger.warn("Watch path inaccessible (volume may be unmounted): \(Logger.c(watchURL.path, .cyan))")
				alertManager.sendIfEnabled(volumeUnavailable: Alert(
					title: "Volume Unavailable",
					subtitle: (watchURL.path as NSString).lastPathComponent,
					body: "Watch path is not accessible (volume may be unmounted):\n\(watchURL.path)",
					severity: .warning
				))
				continue
			}
			walkedPrefixes.insert(watchURL.path)

			guard let enumerator = FileManager.default.enumerator(
				at: watchURL,
				includingPropertiesForKeys: [
					.fileSizeKey,
					.contentModificationDateKey,
					.isDirectoryKey,
					.isRegularFileKey
				],
				options: [.skipsHiddenFiles],
				errorHandler: { url, error in
					self.logger.warn("Cannot access \(Logger.c(url.path, .cyan)): \(error.localizedDescription)")
					return true	 // continue enumeration
				}
			) else {
				logger.warn("Cannot enumerate \(Logger.c(watchURL.path, .cyan))")
				continue
			}

			for case let url as URL in enumerator {
				let resourceValues = try? url.resourceValues(forKeys: [
					.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
				])

				let isDirectory = resourceValues?.isDirectory ?? false
				let isRegularFile = resourceValues?.isRegularFile ?? false

				if isDirectory {
					if !exclusions.shouldDescend(into: url) {
						enumerator.skipDescendants()
						result.filesSkipped += 1
					}
					continue
				}

				guard isRegularFile else { continue }

				let size = Int(resourceValues?.fileSize ?? 0)
				guard exclusions.shouldInclude(fileAt: url, size: size) else {
					result.filesSkipped += 1
					continue
				}

				result.filesWalked += 1
				pathsSeen.insert(url.path)

				if result.filesWalked % 500 == 0 {
					onProgress?("Phase 1: \(Logger.c("\(result.filesWalked)", .yellow)) files discovered")
				}

				let mtime = resourceValues?.contentModificationDate ?? Date()

				// Triage: compare against stored record
				let existingRecord = try store.record(for: url.path)
				if let record = existingRecord {
					let mtimeChanged = abs(mtime.timeIntervalSince1970 - record.mtime.timeIntervalSince1970) > 1.0
					let sizeChanged = Int64(size) != record.size

					if mtimeChanged || sizeChanged {
						// File changed legitimately — re-hash
						toHash.append((url, existingRecord))
					}
					// else: stable — candidate for Phase 3 rolling re-verification
				} else {
					// New file — hash it
					toHash.append((url, nil))
				}
			}
		}

		onProgress?("Phase 1: \(Logger.c("\(result.filesWalked)", .yellow)) files discovered, \(Logger.c("\(toHash.count)", .yellow)) to hash")
		return (toHash, pathsSeen, walkedPrefixes)
	}

	// MARK: - Phase 2: Hash new/modified

	// ============================================================================
	private func runPhase2(
		toHash: [(URL, FileRecord?)],
		result: inout ScanResult
	) async throws {
		guard !toHash.isEmpty else { return }

		let maxThreads = totalHashThreads
		let batchSize = config.performance.dbBatchSize
		let total = toHash.count
		let now = Date()
		let phaseStart = Date()
		var completed = 0

		// Worker pool: keep exactly maxThreads tasks in-flight at once.
		// Per-volume semaphores ensure each disk is accessed by at most its
		// configured number of concurrent hash operations.
		var pendingRecords: [FileRecord] = []

		try await withThrowingTaskGroup(of: FileRecord?.self) { group in
			var iterator = toHash.makeIterator()
			var inFlight = 0

			// Prime the pool
			while inFlight < maxThreads, let item = iterator.next() {
				let fileHasher = self.hasher
				let (url, existing) = item
				let fileProgress = buildFileProgress(
					url: url,
					phaseLabel: "Phase 2: Hashing",
					completed: completed,
					total: total,
					phaseStart: phaseStart
				)
				let semaphore = volumeSemaphore(for: url.path)
				group.addTask {
					await semaphore?.acquire()
					let result = self.hashFile(
						url: url,
						existingRecord: existing,
						hasher: fileHasher,
						now: now,
						onProgress: fileProgress
					)
					await semaphore?.release()
					return result
				}
				inFlight += 1
			}

			while let record = try await group.next() {
				inFlight -= 1
				completed += 1

				let pct = total > 0 ? (completed * 100) / total : 0
				let eta = formatETA(
					started: phaseStart,
					completed: completed,
					total: total
				)
				let fileName = record.map {
					($0.path as NSString).lastPathComponent
				} ?? ""
				let nameSegment = fileName.isEmpty ? "" : " — \(Logger.c(fileName, .cyan))"
				onProgress?("Phase 2: Hashing \(Logger.c("\(completed)", .yellow))/\(Logger.c("\(total)", .yellow)) (\(Logger.c("\(pct)%", .yellow)))\(eta)\(nameSegment)")

				if let fileRecord = record {
					// Track new/modified and log events (moved here from hashFile
					// so that DB writes stay on the actor while hashing runs
					// concurrently off-actor via nonisolated)
					if fileRecord.status == .new {
						result.filesNew += 1
						try store.logEvent(ScanEvent(
							eventType: ScanEvent.fileNew,
							path: fileRecord.path
						))
					} else if fileRecord.status == .modified {
						result.filesModified += 1
						try store.logEvent(ScanEvent(
							eventType: ScanEvent.fileModified,
							path: fileRecord.path
						))
					}

					// Persist with .ok so the file enters Phase 3 rolling verification
					var persisted = fileRecord
					persisted.status = .ok
					pendingRecords.append(persisted)

					// Flush batch to DB
					if pendingRecords.count >= batchSize {
						try store.upsertBatch(pendingRecords)
						pendingRecords.removeAll(keepingCapacity: true)
					}
				}

				// Dispatch next task
				if let item = iterator.next() {
					let fileHasher = self.hasher
					let (url, existing) = item
					let fileProgress = buildFileProgress(
						url: url,
						phaseLabel: "Phase 2: Hashing",
						completed: completed,
						total: total,
						phaseStart: phaseStart
					)
					let semaphore = volumeSemaphore(for: url.path)
					group.addTask {
						await semaphore?.acquire()
						let result = self.hashFile(
							url: url,
							existingRecord: existing,
							hasher: fileHasher,
							now: now,
							onProgress: fileProgress
						)
						await semaphore?.release()
						return result
					}
					inFlight += 1
				}
			}
		}

		// Flush remaining
		if !pendingRecords.isEmpty {
			try store.upsertBatch(pendingRecords)
		}
	}

	// ============================================================================
	/// Hash a single file and return a FileRecord. Runs nonisolated so that
	/// file I/O executes concurrently on the cooperative thread pool instead
	/// of being serialised through the actor. Event logging is done by the
	/// caller (on the actor) after the result is collected.
	nonisolated private func hashFile(
		url: URL,
		existingRecord: FileRecord?,
		hasher: any FileHasher,
		now: Date,
		onProgress fileProgress: HashProgressHandler? = nil
	) -> FileRecord? {
		do {
			let digest = try hasher.hash(fileAt: url, onProgress: fileProgress)
			let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
			let size = (attrs[.size] as? Int64) ?? 0
			let mtime = (attrs[.modificationDate] as? Date) ?? now

			let status: FileStatus = (existingRecord == nil) ? .new : .modified
			let firstSeen = existingRecord?.firstSeen ?? now

			return FileRecord(
				path: url.path,
				size: size,
				mtime: mtime,
				hash: digest,
				hashAlgorithm: hasher.algorithmName,
				firstSeen: firstSeen,
				lastVerified: now,
				lastModified: (status == .modified) ? now : existingRecord?.lastModified,
				status: status
			)
		} catch {
			logger.warn("Cannot hash \(Logger.c(url.path, .cyan)): \(error)")
			return nil
		}
	}

	// MARK: - Phase 3: Rolling re-verification

	// ============================================================================
	private func runPhase3(
		toVerify: [FileRecord],
		result: inout ScanResult
	) async throws {
		guard !toVerify.isEmpty else { return }

		let maxThreads = totalHashThreads
		let batchSize = config.performance.dbBatchSize
		let total = toVerify.count
		let now = Date()
		let phaseStart = Date()
		var completed = 0

		var pendingRecords: [FileRecord] = []

		try await withThrowingTaskGroup(of: FileRecord?.self) { group in
			var iterator = toVerify.makeIterator()
			var inFlight = 0

			while inFlight < maxThreads, let record = iterator.next() {
				let fileHasher = self.hasher
				let recordURL = URL(fileURLWithPath: record.path)
				let fileProgress = buildFileProgress(
					url: recordURL,
					phaseLabel: "Phase 3: Verifying",
					completed: completed,
					total: total,
					phaseStart: phaseStart
				)
				let semaphore = volumeSemaphore(for: record.path)
				group.addTask {
					await semaphore?.acquire()
					let result = self.verifyFile(
						record: record,
						hasher: fileHasher,
						now: now,
						onProgress: fileProgress
					)
					await semaphore?.release()
					return result
				}
				inFlight += 1
			}

			while let verifiedRecord = try await group.next() {
				inFlight -= 1
				completed += 1

				let pct = total > 0 ? (completed * 100) / total : 0
				let eta = formatETA(
					started: phaseStart,
					completed: completed,
					total: total
				)
				let fileName = verifiedRecord.map {
					($0.path as NSString).lastPathComponent
				} ?? ""
				let nameSegment = fileName.isEmpty ? "" : " — \(Logger.c(fileName, .cyan))"
				onProgress?("Phase 3: Verifying \(Logger.c("\(completed)", .yellow))/\(Logger.c("\(total)", .yellow)) (\(Logger.c("\(pct)%", .yellow)))\(eta)\(nameSegment)")

				if let verifiedResult = verifiedRecord {
					pendingRecords.append(verifiedResult)

					if verifiedResult.status == .corrupted {
						result.filesCorrupted += 1
						try store.logEvent(ScanEvent(
							eventType: ScanEvent.fileCorrupted,
							path: verifiedResult.path,
							detail: "{\"stored\":\"\(verifiedResult.hash.prefix(8))\",\"algorithm\":\"\(verifiedResult.hashAlgorithm)\"}"
						))
						alertManager.sendIfEnabled(corruption: Alert(
							title: "File Corruption Detected",
							subtitle: (verifiedResult.path as NSString).lastPathComponent,
							body: "Silent data corruption detected in:\n\(verifiedResult.path)\n\nThe file's content has changed with no modification date change. This may indicate bit-rot or disk hardware failure.",
							severity: .critical
						))
					} else {
						result.filesVerified += 1
					}

					if pendingRecords.count >= batchSize {
						try store.upsertBatch(pendingRecords)
						pendingRecords.removeAll(keepingCapacity: true)
					}
				}

				if let record = iterator.next() {
					let fileHasher = self.hasher
					let recordURL = URL(fileURLWithPath: record.path)
					let fileProgress = buildFileProgress(
						url: recordURL,
						phaseLabel: "Phase 3: Verifying",
						completed: completed,
						total: total,
						phaseStart: phaseStart
					)
					let semaphore = volumeSemaphore(for: record.path)
					group.addTask {
						await semaphore?.acquire()
						let result = self.verifyFile(
							record: record,
							hasher: fileHasher,
							now: now,
							onProgress: fileProgress
						)
						await semaphore?.release()
						return result
					}
					inFlight += 1
				}
			}
		}

		if !pendingRecords.isEmpty {
			try store.upsertBatch(pendingRecords)
		}
	}

	// ============================================================================
	/// Re-verify a single file against its stored hash. Runs nonisolated so
	/// that file I/O executes concurrently on the cooperative thread pool.
	nonisolated private func verifyFile(
		record: FileRecord,
		hasher: any FileHasher,
		now: Date,
		onProgress fileProgress: HashProgressHandler? = nil
	) -> FileRecord? {
		let url = URL(fileURLWithPath: record.path)

		// Check current mtime/size before hashing
		guard let attrs = try? FileManager.default.attributesOfItem(atPath: record.path) else {
			// File disappeared between Phase 1 and Phase 3 — handled in Phase 4
			return nil
		}
		let currentMtime = (attrs[.modificationDate] as? Date) ?? now
		let currentSize = (attrs[.size] as? Int64) ?? 0

		// If mtime or size changed, skip re-verification — Phase 2 will handle it next run
		let mtimeChanged = abs(currentMtime.timeIntervalSince1970 - record.mtime.timeIntervalSince1970) > 1.0
		let sizeChanged = currentSize != record.size
		if mtimeChanged || sizeChanged {
			return nil
		}

		do {
			let computed = try hasher.hash(fileAt: url, onProgress: fileProgress)
			var updated = record
			if computed == record.hash {
				// Clean — update last_verified timestamp
				updated.lastVerified = now
				updated.status = .ok
			} else {
				// Mismatch with unchanged mtime/size = bit-rot
				updated.status = .corrupted
				logger.error("\(Logger.c("BIT-ROT DETECTED:", .boldRed)) \(Logger.c(record.path, .cyan)) (stored: \(Logger.c(String(record.hash.prefix(8)), .yellow))... computed: \(Logger.c(String(computed.prefix(8)), .yellow))...)")
			}
			return updated
		} catch {
			logger.warn("Cannot re-verify \(Logger.c(record.path, .cyan)): \(error)")
			return nil
		}
	}

	// MARK: - Phase 4: Missing file reconciliation

	// ============================================================================
	private func runPhase4(
		pathsSeen: Set<String>,
		walkedPrefixes: Set<String>,
		result: inout ScanResult
	) throws {
		try store.forEachPathBatch(batchSize: 5000) { batch in
			for path in batch {
				guard !pathsSeen.contains(path) else { continue }

				// Skip files under watch paths that were inaccessible (volume
				// may be unmounted). Without this guard, a temporary mount
				// failure would mark every file on that volume as missing.
				guard walkedPrefixes.contains(where: { path.hasPrefix($0) }) else {
					continue
				}

				guard let existing = try store.record(for: path) else {
					continue
				}

				// Skip files that now match exclusion rules added since the
				// file was first tracked. Without this, adding an exclusion
				// pattern would trigger false "missing" alerts for every
				// previously-tracked file matching the new pattern.
				let fileURL = URL(fileURLWithPath: path)
				guard exclusions.shouldInclude(
					fileAt: fileURL,
					size: Int(existing.size)
				) else {
					continue
				}

				try store.deleteRecord(path: path)
				try store.logEvent(ScanEvent(
					eventType: ScanEvent.fileMissing,
					path: path
				))
				result.filesMissing += 1

				alertManager.sendIfEnabled(missingFile: Alert(
					title: "File Missing",
					subtitle: (path as NSString).lastPathComponent,
					body: "A previously tracked file is no longer present:\n\(path)",
					severity: .warning
				))
			}
		}
	}

	// MARK: - Summary helpers

	// ============================================================================
	private func scanSummaryText(_ scanResult: ScanResult) -> String {
		"walked=\(scanResult.filesWalked) new=\(scanResult.filesNew) modified=\(scanResult.filesModified) verified=\(scanResult.filesVerified) corrupted=\(scanResult.filesCorrupted) missing=\(scanResult.filesMissing) skipped=\(scanResult.filesSkipped)"
	}

	// ============================================================================
	private func scanSummaryJSON(_ scanResult: ScanResult) -> String {
		"{\"walked\":\(scanResult.filesWalked),\"new\":\(scanResult.filesNew),\"modified\":\(scanResult.filesModified),\"verified\":\(scanResult.filesVerified),\"corrupted\":\(scanResult.filesCorrupted),\"missing\":\(scanResult.filesMissing)}"
	}

	// ============================================================================
	/// Build a per-file progress callback for large files.
	/// For files below the threshold, returns nil (no per-chunk progress).
	private func buildFileProgress(
		url: URL,
		phaseLabel: String,
		completed: Int,
		total: Int,
		phaseStart: Date
	) -> HashProgressHandler? {
		let fileSize = Int64(
			(try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
		)
		guard fileSize > largeFileThreshold, let onProg = onProgress else {
			return nil
		}

		let fileName = url.lastPathComponent
		let overallPct = total > 0 ? (completed * 100) / total : 0
		let eta = formatETA(
			started: phaseStart,
			completed: completed,
			total: total
		)

		return { bytesHashed, totalSize in
			let filePct = totalSize > 0 ? Int(bytesHashed * 100 / totalSize) : 0
			onProg("\(phaseLabel) \(Logger.c("\(completed)", .yellow))/\(Logger.c("\(total)", .yellow)) (\(Logger.c("\(overallPct)%", .yellow)))\(eta) — \(Logger.c(fileName, .cyan)) (\(Logger.c("\(filePct)%", .yellow)))")
		}
	}

	// ============================================================================
	/// Format estimated remaining time from elapsed seconds and progress.
	private func formatETA(
		started: Date,
		completed: Int,
		total: Int
	) -> String {
		guard completed > 0 else { return "" }
		let elapsed = Date().timeIntervalSince(started)
		let secsPerItem = elapsed / Double(completed)
		let remaining = Int(secsPerItem * Double(total - completed))
		if remaining < 60 { return " — \(Logger.c("\(remaining)s", .yellow)) remaining" }
		let mins = remaining / 60
		let secs = remaining % 60
		if mins < 60 { return " — \(Logger.c("\(mins)m \(secs)s", .yellow)) remaining" }
		let hours = mins / 60
		return " — \(Logger.c("\(hours)h \(mins % 60)m", .yellow)) remaining"
	}
}

// ---------------------------------------------------------------------------
// MARK: - VolumeSemaphore
//
// Limits concurrent tasks per volume.  Used to ensure that each disk is
// accessed by at most N concurrent hash operations (where N is determined
// by the disk type or a manual config override).
// ---------------------------------------------------------------------------

actor VolumeSemaphore {

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	private let limit: Int
	private var current: Int = 0
	private var waiters: [CheckedContinuation<Void, Never>] = []

	// ============================================================================
	init(limit: Int) {
		self.limit = limit
	}

	// ============================================================================
	func acquire() async {
		if current < limit {
			current += 1
			return
		}
		// Wait until a slot is available. The slot is passed to us directly
		// by release() (baton-passing) — current is NOT incremented here
		// because release() skipped the decrement when handing off.
		await withCheckedContinuation { continuation in
			waiters.append(continuation)
		}
	}

	// ============================================================================
	func release() {
		if !waiters.isEmpty {
			// Baton-passing: hand the slot directly to the next waiter without
			// decrementing current. This prevents a race where another acquire()
			// could slip in between the decrement and the waiter's resumption,
			// causing current to exceed the limit.
			let waiter = waiters.removeFirst()
			waiter.resume()
		} else {
			current -= 1
		}
	}
}
