import Foundation
import CryptoKit
import CBLAKE3

// ---------------------------------------------------------------------------
// MARK: - HashUpgradeScanner
//
// Implements the --mode upgrade-hash operation.
//
// For every file record using `fromAlgorithm`:
//	 1. Read the file once, feeding each chunk to both the old and new hasher.
//	 2. Compare the old hash to the stored hash.
//		If it doesn't match → the file is already corrupted. Mark it as
//		corrupted and skip the upgrade (never assign a "clean" new hash to
//		a corrupted file).
//	 3. If it matches → update the record with the new hash.
//
// Single-pass dual hashing halves the I/O compared to hashing twice.
// It's safe to re-run if interrupted — already-upgraded records are skipped
// and each record is persisted to the database immediately on completion.
//
// Uses per-volume semaphores for concurrent hashing: SSDs get multiple
// threads, HDDs get 1 — matching the FileScanner Phase 2/3 pattern.
// Per-file byte progress is reported from the hash callbacks; overall
// completion progress is reported from the single-threaded drain loop.
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
		// Check candidates first — if none, return early without needing valid hashers.
		// This preserves the invariant that an unsupported algorithm name doesn't
		// throw when there are no records to upgrade.
		let candidates = try store.records(withAlgorithm: oldAlgorithm)
		let total = candidates.count

		guard total > 0 else {
			logger.info("Hash upgrade: no records with algorithm \(Logger.c("'\(oldAlgorithm)'", .cyan)) — nothing to do")
			return UpgradeResult()
		}

		let oldHasher = try HasherFactory.make(for: oldAlgorithm)
		let newHasher = try HasherFactory.make(for: newAlgorithm)

		logger.info("Hash upgrade: \(Logger.c("\(total)", .boldWhite)) file(s) to upgrade from \(Logger.c(oldAlgorithm, .cyan)) → \(Logger.c(newAlgorithm, .cyan))")

		try store.logEvent(ScanEvent(
			eventType: ScanEvent.hashUpgradeStart,
			detail: "{\"from\":\"\(oldAlgorithm)\",\"to\":\"\(newAlgorithm)\",\"count\":\(total)}"
		))

		var result = UpgradeResult()
		let maxThreads = totalHashThreads
		let upgradeStart = Date()
		var completed = 0

		try await withThrowingTaskGroup(of: FileUpgradeResult.self) { group in
			var iterator = candidates.makeIterator()
			var inFlight = 0

			// Prime the pool with up to maxThreads initial tasks.
			while inFlight < maxThreads, let record = iterator.next() {
				let semaphore = volumeSemaphore(for: record.path)
				let fileProgress = buildFileProgress(
					fileURL: URL(fileURLWithPath: record.path),
					completed: completed,
					total: total,
					phaseStart: upgradeStart
				)
				group.addTask {
					await semaphore?.acquire()
					let fileResult = self.upgradeFile(
						record: record,
						oldHasher: oldHasher,
						newHasher: newHasher,
						newAlgorithm: newAlgorithm,
						onProgress: fileProgress
					)
					await semaphore?.release()
					return fileResult
				}
				inFlight += 1
			}

			// Drain loop: for each completed task, collect result and add next task.
			// Overall completion progress is reported here (single-threaded) to
			// guarantee clean, monotonically increasing output.
			while let fileResult = try await group.next() {
				inFlight -= 1
				completed += 1

				switch fileResult {
				case .upgraded(let upgradedRecord):
					try store.upsert(upgradedRecord)
					result.upgraded += 1
					reportProgress(
						completed: completed,
						total: total,
						fileName: (upgradedRecord.path as NSString).lastPathComponent,
						phaseStart: upgradeStart
					)

				case .corrupted(let corruptedRecord, let storedPrefix, let computedPrefix):
					try store.upsert(corruptedRecord)
					result.corrupted += 1
					logger.error("\(Logger.c("CORRUPTION DETECTED", .boldRed)) during hash upgrade: \(Logger.c(corruptedRecord.path, .dim))")
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
						total: total,
						fileName: (corruptedRecord.path as NSString).lastPathComponent,
						phaseStart: upgradeStart
					)

				case .skipped(let path):
					result.skipped += 1
					reportProgress(
						completed: completed,
						total: total,
						fileName: (path as NSString).lastPathComponent,
						phaseStart: upgradeStart
					)
				}

				// Add next task from iterator
				if let record = iterator.next() {
					let semaphore = volumeSemaphore(for: record.path)
					let fileProgress = buildFileProgress(
						fileURL: URL(fileURLWithPath: record.path),
						completed: completed,
						total: total,
						phaseStart: upgradeStart
					)
					group.addTask {
						await semaphore?.acquire()
						let fileResult = self.upgradeFile(
							record: record,
							oldHasher: oldHasher,
							newHasher: newHasher,
							newAlgorithm: newAlgorithm,
							onProgress: fileProgress
						)
						await semaphore?.release()
						return fileResult
					}
					inFlight += 1
				}
			}
		}

		onProgress?("")  // clear progress line

		try store.logEvent(ScanEvent(
			eventType: ScanEvent.hashUpgradeComplete,
			detail: "{\"from\":\"\(oldAlgorithm)\",\"to\":\"\(newAlgorithm)\",\"upgraded\":\(result.upgraded),\"corrupted\":\(result.corrupted),\"skipped\":\(result.skipped)}"
		))

		logger.info("\(Logger.c("Hash upgrade complete:", .boldGreen)) upgraded=\(Logger.c("\(result.upgraded)", .boldWhite)) corrupted=\(Logger.c("\(result.corrupted)", result.corrupted > 0 ? .boldRed : .boldWhite)) skipped=\(Logger.c("\(result.skipped)", .boldWhite))")
		return result
	}

	// MARK: - Per-file upgrade (nonisolated for concurrency)

	// ============================================================================
	/// Perform the verify-and-upgrade work for a single file in one pass.
	///
	/// Reads the file once, feeding each chunk to both the old and new hasher
	/// simultaneously. This halves the I/O compared to two separate full reads.
	/// Wrapped in autoreleasepool to contain Foundation memory allocations
	/// (FileHandle/Data buffers).
	nonisolated private func upgradeFile(
		record: FileRecord,
		oldHasher: any FileHasher,
		newHasher: any FileHasher,
		newAlgorithm: String,
		onProgress: HashProgressHandler?
	) -> FileUpgradeResult {
		autoreleasepool {
			let url = URL(fileURLWithPath: record.path)

			let handle: FileHandle
			do {
				handle = try FileHandle(forReadingFrom: url)
			} catch {
				logger.warn("Cannot read \(Logger.c(record.path, .dim)): \(error) — skipping")
				return .skipped(path: record.path)
			}
			defer { try? handle.close() }

			let totalSize = Int64(
				(try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
			)
			let chunkSize = 4 * 1024 * 1024
			var bytesProcessed: Int64 = 0

			// Prepare both hashers for streaming
			var oldSHA = CryptoKit.SHA256()
			var oldBLAKE3State = blake3_hasher()
			let oldIsSHA256 = (oldHasher.algorithmName == "sha256")

			var newSHA = CryptoKit.SHA256()
			var newBLAKE3State = blake3_hasher()
			let newIsSHA256 = (newHasher.algorithmName == "sha256")

			if !oldIsSHA256 { blake3_hasher_init(&oldBLAKE3State) }
			if !newIsSHA256 { blake3_hasher_init(&newBLAKE3State) }

			// Single-pass: read each chunk once, feed to both hashers
			while true {
				let chunk: Data
				do {
					chunk = try handle.read(upToCount: chunkSize) ?? Data()
				} catch {
					logger.warn("Cannot read \(Logger.c(record.path, .dim)): \(error) — skipping")
					return .skipped(path: record.path)
				}
				if chunk.isEmpty { break }

				// Feed old hasher
				if oldIsSHA256 {
					oldSHA.update(data: chunk)
				} else {
					chunk.withUnsafeBytes { buf in
						blake3_hasher_update(&oldBLAKE3State, buf.baseAddress, buf.count)
					}
				}

				// Feed new hasher
				if newIsSHA256 {
					newSHA.update(data: chunk)
				} else {
					chunk.withUnsafeBytes { buf in
						blake3_hasher_update(&newBLAKE3State, buf.baseAddress, buf.count)
					}
				}

				bytesProcessed += Int64(chunk.count)
				onProgress?(bytesProcessed, totalSize)
			}

			// Finalize old hash
			let oldHash: String
			if oldIsSHA256 {
				oldHash = oldSHA.finalize().map { String(format: "%02x", $0) }.joined()
			} else {
				var output = [UInt8](repeating: 0, count: Int(BLAKE3_OUT_LEN))
				blake3_hasher_finalize(&oldBLAKE3State, &output, Int(BLAKE3_OUT_LEN))
				oldHash = output.map { String(format: "%02x", $0) }.joined()
			}

			// Verify old hash
			if oldHash != record.hash {
				var corruptedRecord = record
				corruptedRecord.status = .corrupted
				return .corrupted(
					corruptedRecord,
					storedHashPrefix: String(record.hash.prefix(8)),
					computedHashPrefix: String(oldHash.prefix(8))
				)
			}

			// Finalize new hash
			let newHash: String
			if newIsSHA256 {
				newHash = newSHA.finalize().map { String(format: "%02x", $0) }.joined()
			} else {
				var output = [UInt8](repeating: 0, count: Int(BLAKE3_OUT_LEN))
				blake3_hasher_finalize(&newBLAKE3State, &output, Int(BLAKE3_OUT_LEN))
				newHash = output.map { String(format: "%02x", $0) }.joined()
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
		onProgress("Upgrading \(Logger.c("\(completed)", .yellow))/\(Logger.c("\(total)", .yellow)) (\(Logger.c("\(pct)%", .yellow)))\(eta) — \(fileName)")
	}

	// ============================================================================
	/// Build a per-file progress callback for large files.
	/// For files below the threshold, returns nil (no per-chunk progress).
	/// Captures `completed` by value (frozen at dispatch time) — identical to
	/// FileScanner's pattern. The counter stays fixed while the file hashes,
	/// which looks "paused" rather than "jumping" between concurrent files.
	private func buildFileProgress(
		fileURL: URL,
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

		let fileName = fileURL.lastPathComponent
		let overallPct = total > 0 ? (completed * 100) / total : 0
		let eta = formatETA(
			started: phaseStart,
			completed: completed,
			total: total
		)

		return { bytesHashed, totalSize in
			let filePct = totalSize > 0 ? Int(bytesHashed * 100 / totalSize) : 0
			onProg("Upgrading \(Logger.c("\(completed)", .yellow))/\(Logger.c("\(total)", .yellow)) (\(Logger.c("\(overallPct)%", .yellow)))\(eta) — \(fileName) (\(Logger.c("\(filePct)%", .yellow)))")
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
		if remaining < 60 { return " — \(Logger.c("\(remaining)s", .yellow)) remaining" }
		let mins = remaining / 60
		let secs = remaining % 60
		if mins < 60 { return " — \(Logger.c("\(mins)m \(secs)s", .yellow)) remaining" }
		let hours = mins / 60
		return " — \(Logger.c("\(hours)h \(mins % 60)m", .yellow)) remaining"
	}
}
