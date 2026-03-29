import Foundation

// ---------------------------------------------------------------------------
// MARK: - MirroredManifestStore
//
// Wraps a primary and an optional replica ManifestStore.
// Write operations: primary must succeed (throws on failure); replica is
// best-effort (logs a warning on failure, continues).
// Read operations: always from primary only.
// ---------------------------------------------------------------------------

public final class MirroredManifestStore: ManifestStore {

	private let primary: ManifestStore
	private var replica: ManifestStore?
	private let logger: Logger

	// ============================================================================
	public init(
		primary: ManifestStore,
		replica: ManifestStore?,
		logger: Logger
	) {
		self.primary = primary
		self.replica = replica
		self.logger = logger
	}

	// MARK: - Lifecycle

	// ============================================================================
	public func open() throws {
		try primary.open()

		if let replicaStore = replica {
			do {
				try replicaStore.open()
			} catch {
				logger.warn("Replica database unavailable, continuing without it: \(error)")
				replica = nil
			}
		}
	}

	// ============================================================================
	public func close() {
		primary.close()
		replica?.close()
	}

	// MARK: - Writes (primary required, replica best-effort)

	// ============================================================================
	public func upsert(_ record: FileRecord) throws {
		try primary.upsert(record)
		replicaTry { try $0.upsert(record) }
	}

	// ============================================================================
	public func upsertBatch(_ records: [FileRecord]) throws {
		try primary.upsertBatch(records)
		replicaTry { try $0.upsertBatch(records) }
	}

	// ============================================================================
	public func markMissing(path: String) throws {
		try primary.markMissing(path: path)
		replicaTry { try $0.markMissing(path: path) }
	}

	// ============================================================================
	public func logEvent(_ event: ScanEvent) throws {
		try primary.logEvent(event)
		replicaTry { try $0.logEvent(event) }
	}

	// ============================================================================
	public func insertScan(_ scan: ScanResult) throws -> Int64 {
		let rowid = try primary.insertScan(scan)
		replicaTry { _ = try $0.insertScan(scan) }
		return rowid
	}

	// ============================================================================
	public func updateScan(_ scan: ScanResult) throws {
		try primary.updateScan(scan)
		replicaTry { try $0.updateScan(scan) }
	}

	// MARK: - Reads (primary only)

	// ============================================================================
	public func record(for path: String) throws -> FileRecord? {
		try primary.record(for: path)
	}

	// ============================================================================
	public func records(withAlgorithm algorithm: String) throws -> [FileRecord] {
		try primary.records(withAlgorithm: algorithm)
	}

	// ============================================================================
	public func countRecords(withAlgorithm algorithm: String) throws -> Int {
		try primary.countRecords(withAlgorithm: algorithm)
	}

	// ============================================================================
	public func forEachRecord(
		withAlgorithm algorithm: String,
		batchSize: Int,
		_ body: ([FileRecord]) throws -> Void
	) throws {
		try primary.forEachRecord(
			withAlgorithm: algorithm,
			batchSize: batchSize,
			body
		)
	}

	// ============================================================================
	public func allPaths() throws -> Set<String> {
		try primary.allPaths()
	}

	// ============================================================================
	public func lastScan() throws -> ScanResult? {
		try primary.lastScan()
	}

	// ============================================================================
	public func filesToVerify(
		before date: Date,
		limit: Int
	) throws -> [FileRecord] {
		try primary.filesToVerify(before: date, limit: limit)
	}

	// ============================================================================
	public func allFilesToVerify() throws -> [FileRecord] {
		try primary.allFilesToVerify()
	}

	// MARK: - Streaming iteration (primary only)

	// ============================================================================
	public func forEachRecordBatch(
		batchSize: Int,
		_ body: ([FileRecord]) throws -> Void
	) throws {
		try primary.forEachRecordBatch(batchSize: batchSize, body)
	}

	// ============================================================================
	public func forEachPathBatch(
		batchSize: Int,
		_ body: ([String]) throws -> Void
	) throws {
		try primary.forEachPathBatch(batchSize: batchSize, body)
	}

	// MARK: - Replica sync

	// ============================================================================
	public func syncReplica() throws {
		guard let replicaStore = replica else { return }
		do {
			var count = 0
			try primary.forEachRecordBatch(batchSize: 500) { batch in
				try replicaStore.upsertBatch(batch)
				count += batch.count
			}
			logger.info("Replica sync: \(Logger.c("\(count)", .boldWhite)) record(s) synced")
		} catch {
			logger.warn("Replica sync failed (continuing): \(error)")
		}
	}

	// MARK: - Helper

	// ============================================================================
	private func replicaTry(_ block: (ManifestStore) throws -> Void) {
		guard let replicaStore = replica else { return }
		do {
			try block(replicaStore)
		} catch {
			logger.warn("Replica write failed (continuing): \(error)")
		}
	}
}
