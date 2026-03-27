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

	private let store: ManifestStore
	private let alertManager: AlertManager
	private let logger: Logger

	// ============================================================================
	public init(
		store: ManifestStore,
		alertManager: AlertManager,
		logger: Logger
	) {
		self.store = store
		self.alertManager = alertManager
		self.logger = logger
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
		// Fetch candidates first — if none, return early without needing valid hashers.
		let candidates = try store.records(withAlgorithm: oldAlgorithm)
		guard !candidates.isEmpty else {
			logger.info("Hash upgrade: no records with algorithm '\(oldAlgorithm)' — nothing to do")
			return UpgradeResult()
		}

		let oldHasher = try HasherFactory.make(for: oldAlgorithm)
		let newHasher = try HasherFactory.make(for: newAlgorithm)

		logger.info("Hash upgrade: \(candidates.count) file(s) to upgrade from \(oldAlgorithm) → \(newAlgorithm)")

		try store.logEvent(ScanEvent(
			eventType: ScanEvent.hashUpgradeStart,
			detail: "{\"from\":\"\(oldAlgorithm)\",\"to\":\"\(newAlgorithm)\",\"count\":\(candidates.count)}"
		))

		var result = UpgradeResult()
		var batch: [FileRecord] = []
		let batchSize = 500

		for record in candidates {
			let url = URL(fileURLWithPath: record.path)

			// Verify the old hash before upgrading
			let oldHash: String
			do {
				oldHash = try oldHasher.hash(fileAt: url)
			} catch {
				logger.warn("Cannot read \(record.path): \(error) — skipping")
				result.skipped += 1
				continue
			}

			if oldHash != record.hash {
				// Corruption detected during upgrade — do NOT assign new hash.
				// The record keeps its old hashAlgorithm so a re-run will pick
				// it up again and re-alert (corrupted files should not be silently skipped).
				var corruptedRecord = record
				corruptedRecord.status = .corrupted
				batch.append(corruptedRecord)
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
				continue
			}

			// Hash with new algorithm
			let newHash: String
			do {
				newHash = try newHasher.hash(fileAt: url)
			} catch {
				logger.warn("Cannot hash \(record.path) with \(newAlgorithm): \(error) — skipping")
				result.skipped += 1
				continue
			}

			var upgradedRecord = record
			upgradedRecord.hash = newHash
			upgradedRecord.hashAlgorithm = newAlgorithm
			upgradedRecord.lastVerified = Date()
			upgradedRecord.status = .ok
			batch.append(upgradedRecord)
			result.upgraded += 1

			if batch.count >= batchSize {
				try store.upsertBatch(batch)
				batch.removeAll(keepingCapacity: true)
				logger.info("Hash upgrade progress: \(result.upgraded) upgraded, \(result.corrupted) corrupted")
			}
		}

		if !batch.isEmpty {
			try store.upsertBatch(batch)
		}

		try store.logEvent(ScanEvent(
			eventType: ScanEvent.hashUpgradeComplete,
			detail: "{\"from\":\"\(oldAlgorithm)\",\"to\":\"\(newAlgorithm)\",\"upgraded\":\(result.upgraded),\"corrupted\":\(result.corrupted),\"skipped\":\(result.skipped)}"
		))

		logger.info("Hash upgrade complete: upgraded=\(result.upgraded) corrupted=\(result.corrupted) skipped=\(result.skipped)")
		return result
	}
}
