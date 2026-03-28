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
	private let largeFileThreshold: Int64 = 100 * 1024 * 1024

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
	}

	// MARK: - Public entry point

	// ============================================================================
	public func scan(mode: ScanMode = .full) async throws -> ScanResult {
		var result = ScanResult(startedAt: Date())
		result.id = try store.insertScan(result)

		try store.logEvent(ScanEvent(eventType: ScanEvent.scanStart))
		logger.info("=== Scan started (mode: \(mode)) ===")

		do {
			// Phase 0: RAID health check
			if mode != .filesOnly && config.raid.enabled {
				try await runRAIDPhase()
			}

			// Phases 1–4: file integrity
			result = try await runFilePhases(result: result)
			result.status = .completed

		} catch {
			result.status = .interrupted
			result.completedAt = Date()
			try? store.updateScan(result)
			try store.logEvent(ScanEvent(
				eventType: "scan_error",
				detail: error.localizedDescription
			))
			logger.error("Scan interrupted: \(error)")
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

		logger.info("=== Scan complete: \(scanSummaryText(result)) ===")
		return result
	}

	// MARK: - Phase 0: RAID

	// ============================================================================
	private func runRAIDPhase() async throws {
		logger.info("Phase 0: RAID health check")
		let (_, alerts) = try raidScanner.scan()
		for alert in alerts {
			alertManager.sendIfEnabled(raidAlert: alert)
			let eventType = alert.title.contains("Failed") ? ScanEvent.raidFailed : ScanEvent.raidDegraded
			try store.logEvent(ScanEvent(
				eventType: eventType,
				detail: alert.body
			))
		}
	}

	// MARK: - Phases 1–4: File integrity

	// ============================================================================
	private func runFilePhases(result: ScanResult) async throws -> ScanResult {
		var result = result

		// Pre-scan: sync primary → replica (no-op if no replica configured)
		logger.info("Syncing replica database (if configured)")
		try store.syncReplica()

		// Phase 1: directory walk + triage
		logger.info("Phase 1: Directory walk and triage")
		let (toHash, pathsSeen) = try runPhase1(result: &result)
		onProgress?("")	 // end progress block

		// Phase 2: hash new/modified files
		logger.info("Phase 2: Hashing \(toHash.count) new/modified file(s)")
		try await runPhase2(toHash: toHash, result: &result)
		onProgress?("")	 // end progress block

		// Phase 3: rolling re-verification
		let verificationCutoff = Date().addingTimeInterval(-Double(config.schedule.verificationIntervalDays) * 86400)
		let toVerify = try store.filesToVerify(
			before: verificationCutoff,
			limit: config.performance.maxVerificationsPerRun
		)
		logger.info("Phase 3: Re-verifying \(toVerify.count) file(s)")
		try await runPhase3(toVerify: toVerify, result: &result)
		onProgress?("")	 // end progress block

		// Phase 4: missing file reconciliation
		logger.info("Phase 4: Missing file reconciliation")
		try runPhase4(pathsSeen: pathsSeen, result: &result)

		return result
	}

	// MARK: - Phase 1: Walk

	// ============================================================================
	private func runPhase1(result: inout ScanResult) throws -> (toHash: [(URL, FileRecord?)], pathsSeen: Set<String>) {
		var toHash: [(URL, FileRecord?)] = []
		var pathsSeen = Set<String>()

		for watchURL in config.resolvedWatchPaths {
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
					self.logger.warn("Cannot access \(url.path): \(error.localizedDescription)")
					return true	 // continue enumeration
				}
			) else {
				logger.warn("Cannot enumerate \(watchURL.path)")
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
					onProgress?("Phase 1: \(result.filesWalked) files discovered")
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

		onProgress?("Phase 1: \(result.filesWalked) files discovered, \(toHash.count) to hash")
		return (toHash, pathsSeen)
	}

	// MARK: - Phase 2: Hash new/modified

	// ============================================================================
	private func runPhase2(
		toHash: [(URL, FileRecord?)],
		result: inout ScanResult
	) async throws {
		guard !toHash.isEmpty else { return }

		let maxThreads = config.performance.maxHashThreads
		let batchSize = config.performance.dbBatchSize
		let total = toHash.count
		let now = Date()
		let phaseStart = Date()
		var completed = 0

		// Worker pool: keep exactly maxThreads tasks in-flight at once.
		// We drain with group.next() and add a new task after each completes.
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
				group.addTask {
					try await self.hashFile(
						url: url,
						existingRecord: existing,
						hasher: fileHasher,
						now: now,
						onProgress: fileProgress
					)
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
					truncateFilename(($0.path as NSString).lastPathComponent)
				} ?? ""
				let nameSegment = fileName.isEmpty ? "" : " — \(fileName)"
				onProgress?("Phase 2: Hashing \(completed)/\(total) (\(pct)%)\(eta)\(nameSegment)")

				if let fileRecord = record {
					// Track new/modified for reporting before persisting as .ok
					if fileRecord.status == .new { result.filesNew += 1 }
					else if fileRecord.status == .modified { result.filesModified += 1 }

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
					group.addTask {
						try await self.hashFile(
							url: url,
							existingRecord: existing,
							hasher: fileHasher,
							now: now,
							onProgress: fileProgress
						)
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
	private func hashFile(
		url: URL,
		existingRecord: FileRecord?,
		hasher: any FileHasher,
		now: Date,
		onProgress fileProgress: HashProgressHandler? = nil
	) async throws -> FileRecord? {
		do {
			let digest = try hasher.hash(fileAt: url, onProgress: fileProgress)
			let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
			let size = (attrs[.size] as? Int64) ?? 0
			let mtime = (attrs[.modificationDate] as? Date) ?? now

			// Determine status: new vs modified (used for event logging and counter tracking)
			let status: FileStatus = (existingRecord == nil) ? .new : .modified
			let firstSeen = existingRecord?.firstSeen ?? now

			let record = FileRecord(
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

			if status == .new {
				try store.logEvent(ScanEvent(
					eventType: ScanEvent.fileNew,
					path: url.path
				))
			} else {
				try store.logEvent(ScanEvent(
					eventType: ScanEvent.fileModified,
					path: url.path
				))
			}
			return record
		} catch {
			logger.warn("Cannot hash \(url.path): \(error)")
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

		let maxThreads = config.performance.maxHashThreads
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
				group.addTask {
					try await self.verifyFile(
						record: record,
						hasher: fileHasher,
						now: now,
						onProgress: fileProgress
					)
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
					truncateFilename(($0.path as NSString).lastPathComponent)
				} ?? ""
				let nameSegment = fileName.isEmpty ? "" : " — \(fileName)"
				onProgress?("Phase 3: Verifying \(completed)/\(total) (\(pct)%)\(eta)\(nameSegment)")

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
					group.addTask {
						try await self.verifyFile(
							record: record,
							hasher: fileHasher,
							now: now,
							onProgress: fileProgress
						)
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
	private func verifyFile(
		record: FileRecord,
		hasher: any FileHasher,
		now: Date,
		onProgress fileProgress: HashProgressHandler? = nil
	) async throws -> FileRecord? {
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
				logger.error("BIT-ROT DETECTED: \(record.path) (stored: \(record.hash.prefix(8))... computed: \(computed.prefix(8))...)")
			}
			return updated
		} catch {
			logger.warn("Cannot re-verify \(record.path): \(error)")
			return nil
		}
	}

	// MARK: - Phase 4: Missing file reconciliation

	// ============================================================================
	private func runPhase4(
		pathsSeen: Set<String>,
		result: inout ScanResult
	) throws {
		try store.forEachPathBatch(batchSize: 5000) { batch in
			for path in batch {
				guard !pathsSeen.contains(path) else { continue }
				// Only mark as missing if we don't already know it's missing or corrupted
				if let existing = try store.record(for: path),
				   existing.status != .missing {
					try store.markMissing(path: path)
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

		let fileName = truncateFilename(url.lastPathComponent)
		let overallPct = total > 0 ? (completed * 100) / total : 0
		let eta = formatETA(
			started: phaseStart,
			completed: completed,
			total: total
		)

		return { bytesHashed, totalSize in
			let filePct = totalSize > 0 ? Int(bytesHashed * 100 / totalSize) : 0
			onProg("\(phaseLabel) \(completed)/\(total) (\(overallPct)%)\(eta) — \(fileName) (\(filePct)%)")
		}
	}

	// ============================================================================
	private func truncateFilename(
		_ name: String,
		maxLength: Int = 30
	) -> String {
		guard name.count > maxLength else { return name }
		return String(name.prefix(maxLength - 1)) + "…"
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
		if remaining < 60 { return " — \(remaining)s remaining" }
		let mins = remaining / 60
		let secs = remaining % 60
		if mins < 60 { return " — \(mins)m \(secs)s remaining" }
		let hours = mins / 60
		return " — \(hours)h \(mins % 60)m remaining"
	}
}
