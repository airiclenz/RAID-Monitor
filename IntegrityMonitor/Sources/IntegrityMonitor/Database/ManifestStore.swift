import Foundation

// ---------------------------------------------------------------------------
// MARK: - ManifestStore protocol
//
// All database operations are defined here. Concrete implementations
// (SQLiteManifestStore, MirroredManifestStore) conform to this protocol.
// Nothing outside the Database/ module imports sqlite3 directly.
// ---------------------------------------------------------------------------

public protocol ManifestStore: AnyObject {

	// MARK: Lifecycle
	func open() throws
	func close()

	// MARK: File records
	func upsert(_ record: FileRecord) throws
	func upsertBatch(_ records: [FileRecord]) throws
	func record(for path: String) throws -> FileRecord?
	func records(withAlgorithm algorithm: String) throws -> [FileRecord]
	func countRecords(withAlgorithm algorithm: String) throws -> Int
	func forEachRecord(
		withAlgorithm algorithm: String,
		batchSize: Int,
		_ body: ([FileRecord]) throws -> Void
	) throws

	/// All file paths currently in the manifest. Used for Phase 4 missing-file
	/// reconciliation: caller subtracts the paths seen during the walk.
	func allPaths() throws -> Set<String>

	func deleteRecord(path: String) throws

	// MARK: Events
	func logEvent(_ event: ScanEvent) throws

	// MARK: Scans
	/// Insert a new scan row and return its rowid.
	func insertScan(_ scan: ScanResult) throws -> Int64
	func updateScan(_ scan: ScanResult) throws
	func lastScan() throws -> ScanResult?

	// MARK: Rolling verification
	/// Return up to `limit` file records whose `last_verified` is older than `date`,
	/// ordered ascending by `last_verified` (oldest first).
	func filesToVerify(
		before date: Date,
		limit: Int
	) throws -> [FileRecord]

	/// Return all file records with status 'ok', ordered by last_verified ascending.
	/// Used by `--mode verify` for full on-demand re-verification.
	func allFilesToVerify() throws -> [FileRecord]

	// MARK: Streaming iteration
	/// Iterate all file records in batches. Used for replica sync.
	func forEachRecordBatch(
		batchSize: Int,
		_ body: ([FileRecord]) throws -> Void
	) throws

	/// Iterate all file paths in batches. Used for Phase 4 missing-file detection.
	func forEachPathBatch(
		batchSize: Int,
		_ body: ([String]) throws -> Void
	) throws

	// MARK: Replica sync
	/// Sync all file records from primary to replica. No-op for non-mirrored stores.
	func syncReplica() throws
}

// Default no-op for syncReplica — only MirroredManifestStore overrides this.
public extension ManifestStore {

	// ============================================================================
	func syncReplica() throws {}
}
