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
// ---------------------------------------------------------------------------

public struct HashUpgradeScanner {

	public typealias ProgressHandler = @Sendable (String) -> Void

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	private let store: ManifestStore
	private let alertManager: AlertManager
	private let logger: Logger
	private let onProgress: ProgressHandler?

	/// Files above this size get per-file byte progress in the progress line.
	private let largeFileThreshold: Int64 = 100 * 1024 * 1024

	// ============================================================================
	public init(
		store: ManifestStore,
		alertManager: AlertManager,
		logger: Logger,
		onProgress: ProgressHandler? = nil
	) {
		self.store = store
		self.alertManager = alertManager
		self.logger = logger
		self.onProgress = onProgress
	}

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	public struct UpgradeResult {
		public var upgraded: Int = 0
		public var corrupted: Int = 0
		public var skipped: Int = 0	 // missing or inaccessible
		public var alreadyUpgraded: Int = 0
	}

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

		var result = UpgradeResult()
		let writeBatchSize = 500
		let upgradeStart = Date()

		// Stream records in batches to avoid loading all candidates into memory.
		try store.forEachRecord(
			withAlgorithm: oldAlgorithm,
			batchSize: writeBatchSize
		) { readBatch in
			var writeBatch: [FileRecord] = []

			for record in readBatch {
				// Drain Foundation/ObjC temporaries (FileHandle, Data buffers)
				// after each file to prevent unbounded memory growth.
				try autoreleasepool {
					let url = URL(fileURLWithPath: record.path)
					let fileName = (record.path as NSString).lastPathComponent

					let verifyProgress = buildFileProgress(
						fileName: fileName,
						fileURL: url,
						phaseLabel: "verifying",
						completed: result.upgraded + result.corrupted + result.skipped,
						total: totalCount,
						phaseStart: upgradeStart
					)
					let hashProgress = buildFileProgress(
						fileName: fileName,
						fileURL: url,
						phaseLabel: "hashing",
						completed: result.upgraded + result.corrupted + result.skipped,
						total: totalCount,
						phaseStart: upgradeStart
					)

					// Verify the old hash before upgrading
					let oldHash: String
					do {
						oldHash = try oldHasher.hash(
							fileAt: url,
							onProgress: verifyProgress
						)
					} catch {
						logger.warn("Cannot read \(record.path): \(error) — skipping")
						result.skipped += 1
						reportProgress(
							completed: result.upgraded + result.corrupted + result.skipped,
							total: totalCount,
							fileName: fileName,
							phaseStart: upgradeStart
						)
						return
					}

					if oldHash != record.hash {
						// Corruption detected during upgrade — do NOT assign new hash.
						// The record keeps its old hashAlgorithm so a re-run will pick
						// it up again and re-alert (corrupted files should not be silently skipped).
						var corruptedRecord = record
						corruptedRecord.status = .corrupted
						writeBatch.append(corruptedRecord)
						result.corrupted += 1

						logger.error("CORRUPTION DETECTED during hash upgrade: \(record.path)")
						try store.logEvent(ScanEvent(
							eventType: ScanEvent.fileCorrupted,
							path: record.path,
							detail: "{\"detected_during\":\"hash_upgrade\",\"stored\":\"\(record.hash.prefix(8))\",\"computed\":\"\(oldHash.prefix(8))\"}"
						))
						alertManager.sendIfEnabled(corruption: Alert(
							title: "File Corruption Detected",
							subtitle: (record.path as NSString).lastPathComponent,
							body: "Corruption detected while upgrading hash algorithm:\n\(record.path)\n\nStored \(oldAlgorithm) hash does not match current content.",
							severity: .critical
						))
						reportProgress(
							completed: result.upgraded + result.corrupted + result.skipped,
							total: totalCount,
							fileName: fileName,
							phaseStart: upgradeStart
						)
						return
					}

					// Hash with new algorithm
					let newHash: String
					do {
						newHash = try newHasher.hash(
							fileAt: url,
							onProgress: hashProgress
						)
					} catch {
						logger.warn("Cannot hash \(record.path) with \(newAlgorithm): \(error) — skipping")
						result.skipped += 1
						reportProgress(
							completed: result.upgraded + result.corrupted + result.skipped,
							total: totalCount,
							fileName: fileName,
							phaseStart: upgradeStart
						)
						return
					}

					var upgradedRecord = record
					upgradedRecord.hash = newHash
					upgradedRecord.hashAlgorithm = newAlgorithm
					upgradedRecord.lastVerified = Date()
					upgradedRecord.status = .ok
					writeBatch.append(upgradedRecord)
					result.upgraded += 1

					reportProgress(
						completed: result.upgraded + result.corrupted + result.skipped,
						total: totalCount,
						fileName: fileName,
						phaseStart: upgradeStart
					)
				}
			}

			if !writeBatch.isEmpty {
				try store.upsertBatch(writeBatch)
			}
		}

		onProgress?("")  // clear progress line

		try store.logEvent(ScanEvent(
			eventType: ScanEvent.hashUpgradeComplete,
			detail: "{\"from\":\"\(oldAlgorithm)\",\"to\":\"\(newAlgorithm)\",\"upgraded\":\(result.upgraded),\"corrupted\":\(result.corrupted),\"skipped\":\(result.skipped)}"
		))

		logger.info("Hash upgrade complete: upgraded=\(result.upgraded) corrupted=\(result.corrupted) skipped=\(result.skipped)")
		return result
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
