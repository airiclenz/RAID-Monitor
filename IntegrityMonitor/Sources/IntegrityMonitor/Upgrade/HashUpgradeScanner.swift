import Foundation

// ---------------------------------------------------------------------------
// MARK: - HashUpgradeScanner
//
// Implements the --mode upgrade-hash operation.
//
// For every file record using `fromAlgorithm`:
//	 1. Re-hash with the old algorithm and verify it matches the stored hash.
//		If it doesn't match → the file is already corrupted. Mark it as
//		corrupted and skip the upgrade (never assign a "clean" new hash to
//		a corrupted file).
//	 2. If it matches → hash with the new algorithm, update the record.
//
// It's safe to re-run if interrupted — already-upgraded records are skipped.
//
// Uses per-volume semaphores for concurrent hashing: SSDs get multiple
// threads, HDDs get 1 — matching the FileScanner Phase 2/3 pattern.
// ---------------------------------------------------------------------------

public struct HashUpgradeScanner {

	public typealias ProgressHandler = @Sendable (String) -> Void

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	private let config: Config
	private let store: ManifestStore
	private let alertManager: AlertManager
	private let logger: Logger
	private let onProgress: ProgressHandler?

	/// Files above this size get per-file byte progress in the progress line.
	private let largeFileThreshold: Int64 = 100 * 1024 * 1024

	/// Per-volume concurrency info, keyed by device ID.
	private let volumeMap: [dev_t: VolumeInfo]

	/// Per-volume semaphores that gate concurrent hash reads.
	private let volumeSemaphores: [dev_t: VolumeSemaphore]

	// ============================================================================
	public init(
		store: ManifestStore,
		config: Config,
		alertManager: AlertManager,
		logger: Logger,
		onProgress: ProgressHandler? = nil
	) {
		self.store = store
		self.config = config
		self.alertManager = alertManager
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

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	public struct UpgradeResult {
		public var upgraded: Int = 0
		public var corrupted: Int = 0
		public var skipped: Int = 0	 // missing or inaccessible
		public var alreadyUpgraded: Int = 0
	}

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	/// Result of upgrading a single file, returned from the TaskGroup.
	private enum FileUpgradeResult: Sendable {
		case upgraded(FileRecord)
		case corrupted(FileRecord, storedHashPrefix: String, computedHashPrefix: String)
		case skipped(path: String)
	}

	// MARK: - Volume helpers

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
	public func upgrade(
		from oldAlgorithm: String,
		to newAlgorithm: String
	) async throws -> UpgradeResult {
		// Check count first — if none, return early without needing valid hashers.
		let totalCount = try store.countRecords(withAlgorithm: oldAlgorithm)
		guard totalCount > 0 else {
			logger.info("Hash upgrade: no records with algorithm '\(oldAlgorithm)' — nothing to do")
			return UpgradeResult()
		}

		let oldHasher = try HasherFactory.make(for: oldAlgorithm)
		let newHasher = try HasherFactory.make(for: newAlgorithm)

		logger.info("Hash upgrade: \(totalCount) file(s) to upgrade from \(oldAlgorithm) → \(newAlgorithm)")

		try store.logEvent(ScanEvent(
			eventType: ScanEvent.hashUpgradeStart,
			detail: "{\"from\":\"\(oldAlgorithm)\",\"to\":\"\(newAlgorithm)\",\"count\":\(totalCount)}"
		))

		// Load all candidates. At ~200 bytes per FileRecord, even 100K records is
		// only ~20 MB. The memory problem was from accumulated Data hashing buffers,
		// which autoreleasepool in upgradeFile() already fixes.
		let candidates = try store.records(withAlgorithm: oldAlgorithm)

		var result = UpgradeResult()
		let batchSize = config.performance.dbBatchSize
		let maxThreads = totalHashThreads
		let upgradeStart = Date()
		var completed = 0
		var pendingRecords: [FileRecord] = []

		try await withThrowingTaskGroup(of: FileUpgradeResult.self) { group in
			var iterator = candidates.makeIterator()
			var inFlight = 0

			// Prime the pool with up to maxThreads initial tasks.
			while inFlight < maxThreads, let record = iterator.next() {
				let semaphore = volumeSemaphore(for: record.path)
				let fileProgress = buildFileProgress(
					fileName: (record.path as NSString).lastPathComponent,
					fileURL: URL(fileURLWithPath: record.path),
					phaseLabel: "verifying",
					completed: completed,
					total: totalCount,
					phaseStart: upgradeStart
				)
				group.addTask {
					await semaphore?.acquire()
					let fileResult = self.upgradeFile(
						record: record,
						oldHasher: oldHasher,
						newHasher: newHasher,
						oldAlgorithm: oldAlgorithm,
						newAlgorithm: newAlgorithm,
						verifyProgress: fileProgress
					)
					await semaphore?.release()
					return fileResult
				}
				inFlight += 1
			}

			// Drain loop: for each completed task, collect result and add next task.
			while let fileResult = try await group.next() {
				inFlight -= 1
				completed += 1

				switch fileResult {
				case .upgraded(let upgradedRecord):
					pendingRecords.append(upgradedRecord)
					result.upgraded += 1
					reportProgress(
						completed: completed,
						total: totalCount,
						fileName: (upgradedRecord.path as NSString).lastPathComponent,
						phaseStart: upgradeStart
					)

				case .corrupted(let corruptedRecord, let storedPrefix, let computedPrefix):
					pendingRecords.append(corruptedRecord)
					result.corrupted += 1
					logger.error("CORRUPTION DETECTED during hash upgrade: \(corruptedRecord.path)")
					try store.logEvent(ScanEvent(
						eventType: ScanEvent.fileCorrupted,
						path: corruptedRecord.path,
						detail: "{\"detected_during\":\"hash_upgrade\",\"stored\":\"\(storedPrefix)\",\"computed\":\"\(computedPrefix)\"}"
					))
					alertManager.sendIfEnabled(corruption: Alert(
						title: "File Corruption Detected",
						subtitle: (corruptedRecord.path as NSString).lastPathComponent,
						body: "Corruption detected while upgrading hash algorithm:\n\(corruptedRecord.path)\n\nStored \(oldAlgorithm) hash does not match current content.",
						severity: .critical
					))
					reportProgress(
						completed: completed,
						total: totalCount,
						fileName: (corruptedRecord.path as NSString).lastPathComponent,
						phaseStart: upgradeStart
					)

				case .skipped(let path):
					result.skipped += 1
					reportProgress(
						completed: completed,
						total: totalCount,
						fileName: (path as NSString).lastPathComponent,
						phaseStart: upgradeStart
					)
				}

				// Flush DB batch
				if pendingRecords.count >= batchSize {
					try store.upsertBatch(pendingRecords)
					pendingRecords.removeAll(keepingCapacity: true)
				}

				// Add next task from iterator
				if let record = iterator.next() {
					let semaphore = volumeSemaphore(for: record.path)
					let fileProgress = buildFileProgress(
						fileName: (record.path as NSString).lastPathComponent,
						fileURL: URL(fileURLWithPath: record.path),
						phaseLabel: "verifying",
						completed: completed,
						total: totalCount,
						phaseStart: upgradeStart
					)
					group.addTask {
						await semaphore?.acquire()
						let fileResult = self.upgradeFile(
							record: record,
							oldHasher: oldHasher,
							newHasher: newHasher,
							oldAlgorithm: oldAlgorithm,
							newAlgorithm: newAlgorithm,
							verifyProgress: fileProgress
						)
						await semaphore?.release()
						return fileResult
					}
					inFlight += 1
				}
			}
		}

		// Flush remaining records
		if !pendingRecords.isEmpty {
			try store.upsertBatch(pendingRecords)
		}

		onProgress?("")  // clear progress line

		try store.logEvent(ScanEvent(
			eventType: ScanEvent.hashUpgradeComplete,
			detail: "{\"from\":\"\(oldAlgorithm)\",\"to\":\"\(newAlgorithm)\",\"upgraded\":\(result.upgraded),\"corrupted\":\(result.corrupted),\"skipped\":\(result.skipped)}"
		))

		logger.info("Hash upgrade complete: upgraded=\(result.upgraded) corrupted=\(result.corrupted) skipped=\(result.skipped)")
		return result
	}

	// MARK: - Per-file upgrade (nonisolated for concurrency)

	// ============================================================================
	/// Perform the verify-then-upgrade work for a single file.
	/// Runs inside autoreleasepool to contain Foundation memory allocations.
	/// This is a pure I/O function with no shared mutable state.
	nonisolated private func upgradeFile(
		record: FileRecord,
		oldHasher: any FileHasher,
		newHasher: any FileHasher,
		oldAlgorithm: String,
		newAlgorithm: String,
		verifyProgress: HashProgressHandler?
	) -> FileUpgradeResult {
		autoreleasepool {
			let url = URL(fileURLWithPath: record.path)

			// Step 1: Verify the old hash
			let oldHash: String
			do {
				oldHash = try oldHasher.hash(
					fileAt: url,
					onProgress: verifyProgress
				)
			} catch {
				logger.warn("Cannot read \(record.path): \(error) — skipping")
				return .skipped(path: record.path)
			}

			if oldHash != record.hash {
				// Corruption detected — do NOT assign new hash.
				var corruptedRecord = record
				corruptedRecord.status = .corrupted
				return .corrupted(
					corruptedRecord,
					storedHashPrefix: String(record.hash.prefix(8)),
					computedHashPrefix: String(oldHash.prefix(8))
				)
			}

			// Step 2: Hash with new algorithm
			let newHash: String
			do {
				newHash = try newHasher.hash(fileAt: url, onProgress: nil)
			} catch {
				logger.warn("Cannot hash \(record.path) with \(newAlgorithm): \(error) — skipping")
				return .skipped(path: record.path)
			}

			var upgradedRecord = record
			upgradedRecord.hash = newHash
			upgradedRecord.hashAlgorithm = newAlgorithm
			upgradedRecord.lastVerified = Date()
			upgradedRecord.status = .ok
			return .upgraded(upgradedRecord)
		}
	}

	// MARK: - Progress helpers

	// ============================================================================
	private func reportProgress(
		completed: Int,
		total: Int,
		fileName: String,
		phaseStart: Date
	) {
		guard let onProgress = onProgress else { return }
		let pct = total > 0 ? (completed * 100) / total : 0
		let eta = formatETA(
			started: phaseStart,
			completed: completed,
			total: total
		)
		onProgress("Upgrading \(completed)/\(total) (\(pct)%)\(eta) — \(fileName)")
	}

	// ============================================================================
	/// Build a per-file progress callback for large files.
	/// For files below the threshold, returns nil (no per-chunk progress).
	private func buildFileProgress(
		fileName: String,
		fileURL: URL,
		phaseLabel: String,
		completed: Int,
		total: Int,
		phaseStart: Date
	) -> HashProgressHandler? {
		let fileSize = Int64(
			(try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
		)
		guard fileSize > largeFileThreshold, let onProg = onProgress else {
			return nil
		}

		let overallPct = total > 0 ? (completed * 100) / total : 0
		let eta = formatETA(
			started: phaseStart,
			completed: completed,
			total: total
		)

		return { bytesHashed, totalSize in
			let filePct = totalSize > 0 ? Int(bytesHashed * 100 / totalSize) : 0
			onProg("Upgrading \(completed)/\(total) (\(overallPct)%)\(eta) — \(fileName) \(phaseLabel) (\(filePct)%)")
		}
	}

	// ============================================================================
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
