import Foundation
import SQLite3

// ---------------------------------------------------------------------------
// MARK: - SQLiteManifestStore
//
// Concrete ManifestStore backed by an on-disk SQLite database.
// Uses the raw sqlite3 C API (no third-party wrappers) per the spec's
// zero-external-dependency requirement.
//
// Thread safety: this class is NOT thread-safe. Callers must not call from
// multiple threads concurrently. In practice the app is single-threaded in
// its database operations (the actor FileScanner serialises all DB access).
// ---------------------------------------------------------------------------

public final class SQLiteManifestStore: ManifestStore {

	private let path: URL
	private var db: OpaquePointer?

	// ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

	// Prepared statements (prepared once in open(), finalized in close())
	private var stmtUpsertFile: OpaquePointer?
	private var stmtSelectFile: OpaquePointer?
	private var stmtAllPaths: OpaquePointer?
	private var stmtMarkMissing: OpaquePointer?
	private var stmtInsertEvent: OpaquePointer?
	private var stmtInsertScan: OpaquePointer?
	private var stmtUpdateScan: OpaquePointer?
	private var stmtLastScan: OpaquePointer?
	private var stmtFilesToVerify: OpaquePointer?
	private var stmtAllFilesToVerify: OpaquePointer?
	private var stmtSelectByAlgorithm: OpaquePointer?
	private var stmtAllRecords: OpaquePointer?

	// ============================================================================
	public init(path: URL) {
		self.path = path
	}

	// ============================================================================
	deinit {
		close()
	}

	// MARK: - Lifecycle

	// ============================================================================
	public func open() throws {
		var handle: OpaquePointer?
		let rc = sqlite3_open(path.path, &handle)
		guard rc == SQLITE_OK, let dbHandle = handle else {
			let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
			sqlite3_close(handle)
			throw AppError.database("Cannot open database at \(path.path): \(msg)")
		}
		db = dbHandle

		try applyPragmas()
		try createSchema()
		try prepareStatements()
	}

	// ============================================================================
	public func close() {
		let stmts: [OpaquePointer?] = [
			stmtUpsertFile, stmtSelectFile, stmtAllPaths, stmtMarkMissing,
			stmtInsertEvent, stmtInsertScan, stmtUpdateScan, stmtLastScan,
			stmtFilesToVerify, stmtAllFilesToVerify, stmtSelectByAlgorithm,
			stmtAllRecords
		]
		for stmt in stmts { sqlite3_finalize(stmt) }
		stmtUpsertFile = nil; stmtSelectFile = nil; stmtAllPaths = nil
		stmtMarkMissing = nil; stmtInsertEvent = nil; stmtInsertScan = nil
		stmtUpdateScan = nil; stmtLastScan = nil; stmtFilesToVerify = nil
		stmtAllFilesToVerify = nil; stmtSelectByAlgorithm = nil
		stmtAllRecords = nil

		sqlite3_close(db)
		db = nil
	}

	// MARK: - File records

	// ============================================================================
	public func upsert(_ record: FileRecord) throws {
		try upsertBatch([record])
	}

	// ============================================================================
	public func upsertBatch(_ records: [FileRecord]) throws {
		guard db != nil else { throw AppError.database("Database not open") }
		guard !records.isEmpty else { return }

		try exec("BEGIN IMMEDIATE")
		do {
			for record in records {
				try bindAndStepUpsert(record)
			}
			try exec("COMMIT")
		} catch {
			try? exec("ROLLBACK")
			throw error
		}
	}

	// ============================================================================
	public func record(for path: String) throws -> FileRecord? {
		guard let stmt = stmtSelectFile else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
		let rc = sqlite3_step(stmt)
		if rc == SQLITE_DONE { return nil }
		guard rc == SQLITE_ROW else {
			throw AppError.database("SELECT file failed: \(dbError())")
		}
		return extractFileRecord(from: stmt)
	}

	// ============================================================================
	public func records(withAlgorithm algorithm: String) throws -> [FileRecord] {
		guard let stmt = stmtSelectByAlgorithm else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		sqlite3_bind_text(stmt, 1, algorithm, -1, SQLITE_TRANSIENT)
		var results: [FileRecord] = []
		while true {
			let rc = sqlite3_step(stmt)
			if rc == SQLITE_DONE { break }
			guard rc == SQLITE_ROW else {
				throw AppError.database("SELECT by algorithm failed: \(dbError())")
			}
			results.append(extractFileRecord(from: stmt))
		}
		return results
	}

	// ============================================================================
	public func allPaths() throws -> Set<String> {
		guard let stmt = stmtAllPaths else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		var paths = Set<String>()
		while true {
			let rc = sqlite3_step(stmt)
			if rc == SQLITE_DONE { break }
			guard rc == SQLITE_ROW else {
				throw AppError.database("SELECT all paths failed: \(dbError())")
			}
			if let cStr = sqlite3_column_text(stmt, 0) {
				paths.insert(String(cString: cStr))
			}
		}
		return paths
	}

	// ============================================================================
	public func forEachRecordBatch(
		batchSize: Int,
		_ body: ([FileRecord]) throws -> Void
	) throws {
		guard let stmt = stmtAllRecords else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		var batch: [FileRecord] = []
		batch.reserveCapacity(batchSize)
		while true {
			let rc = sqlite3_step(stmt)
			if rc == SQLITE_DONE { break }
			guard rc == SQLITE_ROW else {
				throw AppError.database("SELECT all records failed: \(dbError())")
			}
			batch.append(extractFileRecord(from: stmt))
			if batch.count >= batchSize {
				try body(batch)
				batch.removeAll(keepingCapacity: true)
			}
		}
		if !batch.isEmpty { try body(batch) }
	}

	// ============================================================================
	public func forEachPathBatch(
		batchSize: Int,
		_ body: ([String]) throws -> Void
	) throws {
		guard let stmt = stmtAllPaths else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		var batch: [String] = []
		batch.reserveCapacity(batchSize)
		while true {
			let rc = sqlite3_step(stmt)
			if rc == SQLITE_DONE { break }
			guard rc == SQLITE_ROW else {
				throw AppError.database("SELECT all paths failed: \(dbError())")
			}
			if let cStr = sqlite3_column_text(stmt, 0) {
				batch.append(String(cString: cStr))
			}
			if batch.count >= batchSize {
				try body(batch)
				batch.removeAll(keepingCapacity: true)
			}
		}
		if !batch.isEmpty { try body(batch) }
	}

	// ============================================================================
	public func markMissing(path: String) throws {
		guard let stmt = stmtMarkMissing else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
		let rc = sqlite3_step(stmt)
		guard rc == SQLITE_DONE else {
			throw AppError.database("markMissing failed for \(path): \(dbError())")
		}
	}

	// MARK: - Events

	// ============================================================================
	public func logEvent(_ event: ScanEvent) throws {
		guard let stmt = stmtInsertEvent else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		sqlite3_bind_double(stmt, 1, event.timestamp.timeIntervalSince1970)
		sqlite3_bind_text(stmt, 2, event.eventType, -1, SQLITE_TRANSIENT)
		bindOptionalText(stmt, index: 3, value: event.path)
		bindOptionalText(stmt, index: 4, value: event.detail)

		let rc = sqlite3_step(stmt)
		guard rc == SQLITE_DONE else {
			throw AppError.database("INSERT event failed: \(dbError())")
		}
	}

	// MARK: - Scans

	// ============================================================================
	public func insertScan(_ scan: ScanResult) throws -> Int64 {
		guard let stmt = stmtInsertScan, let db = db else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		sqlite3_bind_double(stmt, 1, scan.startedAt.timeIntervalSince1970)
		sqlite3_bind_text(stmt, 2, scan.status.rawValue, -1, SQLITE_TRANSIENT)

		let rc = sqlite3_step(stmt)
		guard rc == SQLITE_DONE else {
			throw AppError.database("INSERT scan failed: \(dbError())")
		}
		return sqlite3_last_insert_rowid(db)
	}

	// ============================================================================
	public func updateScan(_ scan: ScanResult) throws {
		guard let stmt = stmtUpdateScan else { throw AppError.database("Database not open") }
		guard let scanId = scan.id else { throw AppError.database("Cannot update scan without id") }
		defer { sqlite3_reset(stmt) }

		sqlite3_bind_double(stmt, 1, (scan.completedAt ?? Date()).timeIntervalSince1970)
		sqlite3_bind_int(stmt, 2, Int32(scan.filesWalked))
		sqlite3_bind_int(stmt, 3, Int32(scan.filesSkipped))
		sqlite3_bind_int(stmt, 4, Int32(scan.filesNew))
		sqlite3_bind_int(stmt, 5, Int32(scan.filesModified))
		sqlite3_bind_int(stmt, 6, Int32(scan.filesVerified))
		sqlite3_bind_int(stmt, 7, Int32(scan.filesCorrupted))
		sqlite3_bind_int(stmt, 8, Int32(scan.filesMissing))
		sqlite3_bind_int(stmt, 9, Int32(scan.filesUpgraded))
		sqlite3_bind_text(stmt, 10, scan.status.rawValue, -1, SQLITE_TRANSIENT)
		sqlite3_bind_int64(stmt, 11, scanId)

		let rc = sqlite3_step(stmt)
		guard rc == SQLITE_DONE else {
			throw AppError.database("UPDATE scan failed: \(dbError())")
		}
	}

	// ============================================================================
	public func lastScan() throws -> ScanResult? {
		guard let stmt = stmtLastScan else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		let rc = sqlite3_step(stmt)
		if rc == SQLITE_DONE { return nil }
		guard rc == SQLITE_ROW else {
			throw AppError.database("SELECT last scan failed: \(dbError())")
		}
		return extractScanResult(from: stmt)
	}

	// MARK: - Rolling verification

	// ============================================================================
	public func filesToVerify(
		before date: Date,
		limit: Int
	) throws -> [FileRecord] {
		guard let stmt = stmtFilesToVerify else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
		sqlite3_bind_int(stmt, 2, Int32(limit))

		var results: [FileRecord] = []
		while true {
			let rc = sqlite3_step(stmt)
			if rc == SQLITE_DONE { break }
			guard rc == SQLITE_ROW else {
				throw AppError.database("filesToVerify query failed: \(dbError())")
			}
			results.append(extractFileRecord(from: stmt))
		}
		return results
	}

	// ============================================================================
	public func allFilesToVerify() throws -> [FileRecord] {
		guard let stmt = stmtAllFilesToVerify else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		var results: [FileRecord] = []
		while true {
			let rc = sqlite3_step(stmt)
			if rc == SQLITE_DONE { break }
			guard rc == SQLITE_ROW else {
				throw AppError.database("allFilesToVerify query failed: \(dbError())")
			}
			results.append(extractFileRecord(from: stmt))
		}
		return results
	}

	// MARK: - Schema

	// ============================================================================
	private func applyPragmas() throws {
		try exec("PRAGMA journal_mode = WAL")
		try exec("PRAGMA busy_timeout = 5000")
		try exec("PRAGMA synchronous = NORMAL")
		try exec("PRAGMA foreign_keys = ON")
		try exec("PRAGMA cache_size = -8000")
	}

	// ============================================================================
	private func createSchema() throws {
		let ddl = """
		CREATE TABLE IF NOT EXISTS files (
			id				 INTEGER PRIMARY KEY,
			path			 TEXT	 UNIQUE NOT NULL,
			size			 INTEGER NOT NULL,
			mtime			 REAL	 NOT NULL,
			hash			 TEXT	 NOT NULL,
			hash_algorithm	 TEXT	 NOT NULL,
			first_seen		 REAL	 NOT NULL,
			last_verified	 REAL	 NOT NULL,
			last_modified	 REAL,
			status			 TEXT	 NOT NULL DEFAULT 'ok'
		);
		CREATE INDEX IF NOT EXISTS idx_files_last_verified	ON files(last_verified);
		CREATE INDEX IF NOT EXISTS idx_files_hash_algorithm ON files(hash_algorithm);
		CREATE INDEX IF NOT EXISTS idx_files_status			ON files(status);
		CREATE INDEX IF NOT EXISTS idx_files_verify_rolling ON files(status, last_verified);

		CREATE TABLE IF NOT EXISTS events (
			id			INTEGER PRIMARY KEY,
			timestamp	REAL	NOT NULL,
			event_type	TEXT	NOT NULL,
			path		TEXT,
			detail		TEXT
		);

		CREATE TABLE IF NOT EXISTS scans (
			id				 INTEGER PRIMARY KEY,
			started_at		 REAL	 NOT NULL,
			completed_at	 REAL,
			files_walked	 INTEGER NOT NULL DEFAULT 0,
			files_skipped	 INTEGER NOT NULL DEFAULT 0,
			files_new		 INTEGER NOT NULL DEFAULT 0,
			files_modified	 INTEGER NOT NULL DEFAULT 0,
			files_verified	 INTEGER NOT NULL DEFAULT 0,
			files_corrupted	 INTEGER NOT NULL DEFAULT 0,
			files_missing	 INTEGER NOT NULL DEFAULT 0,
			files_upgraded	 INTEGER NOT NULL DEFAULT 0,
			status			 TEXT	 NOT NULL DEFAULT 'running'
		);

		CREATE TABLE IF NOT EXISTS schema_version (
			version INTEGER NOT NULL
		);
		INSERT OR IGNORE INTO schema_version VALUES (1);
		"""
		// Execute each statement separately (sqlite3_exec handles multiple with semicolons)
		try exec(ddl)
	}

	// ============================================================================
	private func prepareStatements() throws {
		stmtUpsertFile = try prepare("""
			INSERT INTO files
				(path, size, mtime, hash, hash_algorithm, first_seen, last_verified, last_modified, status)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(path) DO UPDATE SET
				size		   = excluded.size,
				mtime		   = excluded.mtime,
				hash		   = excluded.hash,
				hash_algorithm = excluded.hash_algorithm,
				last_verified  = excluded.last_verified,
				last_modified  = excluded.last_modified,
				status		   = excluded.status
			""")

		stmtSelectFile = try prepare(
			"SELECT id, path, size, mtime, hash, hash_algorithm, first_seen, last_verified, last_modified, status FROM files WHERE path = ?"
		)

		stmtAllPaths = try prepare("SELECT path FROM files")

		stmtMarkMissing = try prepare("UPDATE files SET status = 'missing' WHERE path = ?")

		stmtInsertEvent = try prepare(
			"INSERT INTO events (timestamp, event_type, path, detail) VALUES (?, ?, ?, ?)"
		)

		stmtInsertScan = try prepare("INSERT INTO scans (started_at, status) VALUES (?, ?)")

		stmtUpdateScan = try prepare("""
			UPDATE scans SET
				completed_at	= ?,
				files_walked	= ?,
				files_skipped	= ?,
				files_new		= ?,
				files_modified	= ?,
				files_verified	= ?,
				files_corrupted = ?,
				files_missing	= ?,
				files_upgraded	= ?,
				status			= ?
			WHERE id = ?
			""")

		stmtLastScan = try prepare("""
			SELECT id, started_at, completed_at,
				   files_walked, files_skipped, files_new, files_modified,
				   files_verified, files_corrupted, files_missing, files_upgraded, status
			FROM scans ORDER BY started_at DESC LIMIT 1
			""")

		stmtFilesToVerify = try prepare("""
			SELECT id, path, size, mtime, hash, hash_algorithm, first_seen, last_verified, last_modified, status
			FROM files
			WHERE last_verified < ? AND status = 'ok'
			ORDER BY last_verified ASC
			LIMIT ?
			""")

		stmtAllFilesToVerify = try prepare("""
			SELECT id, path, size, mtime, hash, hash_algorithm, first_seen, last_verified, last_modified, status
			FROM files
			WHERE status = 'ok'
			ORDER BY last_verified ASC
			""")

		stmtSelectByAlgorithm = try prepare("""
			SELECT id, path, size, mtime, hash, hash_algorithm, first_seen, last_verified, last_modified, status
			FROM files WHERE hash_algorithm = ?
			""")

		stmtAllRecords = try prepare(
			"SELECT id, path, size, mtime, hash, hash_algorithm, first_seen, last_verified, last_modified, status FROM files"
		)
	}

	// MARK: - Statement execution helpers

	// ============================================================================
	private func prepare(_ sql: String) throws -> OpaquePointer {
		guard let db = db else { throw AppError.database("Database not open") }
		var stmt: OpaquePointer?
		let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
		guard rc == SQLITE_OK, let statement = stmt else {
			throw AppError.database("Failed to prepare statement [\(sql.prefix(60))...]: \(dbError())")
		}
		return statement
	}

	// ============================================================================
	private func exec(_ sql: String) throws {
		guard let db = db else { throw AppError.database("Database not open") }
		var errMsg: UnsafeMutablePointer<CChar>?
		let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
		if rc != SQLITE_OK {
			let msg = errMsg.map { String(cString: $0) } ?? "unknown"
			sqlite3_free(errMsg)
			throw AppError.database("sqlite3_exec failed: \(msg)")
		}
	}

	// ============================================================================
	private func bindAndStepUpsert(_ record: FileRecord) throws {
		guard let stmt = stmtUpsertFile else { throw AppError.database("Database not open") }
		defer { sqlite3_reset(stmt) }

		sqlite3_bind_text(stmt, 1, record.path, -1, SQLITE_TRANSIENT)
		sqlite3_bind_int64(stmt, 2, record.size)
		sqlite3_bind_double(stmt, 3, record.mtime.timeIntervalSince1970)
		sqlite3_bind_text(stmt, 4, record.hash, -1, SQLITE_TRANSIENT)
		sqlite3_bind_text(stmt, 5, record.hashAlgorithm, -1, SQLITE_TRANSIENT)
		sqlite3_bind_double(stmt, 6, record.firstSeen.timeIntervalSince1970)
		sqlite3_bind_double(stmt, 7, record.lastVerified.timeIntervalSince1970)
		bindOptionalDouble(
			stmt,
			index: 8,
			value: record.lastModified?.timeIntervalSince1970
		)
		sqlite3_bind_text(stmt, 9, record.status.rawValue, -1, SQLITE_TRANSIENT)

		let rc = sqlite3_step(stmt)
		guard rc == SQLITE_DONE else {
			throw AppError.database("Upsert failed for \(record.path): \(dbError())")
		}
	}

	// MARK: - Row extraction helpers

	// ============================================================================
	private func extractFileRecord(from stmt: OpaquePointer) -> FileRecord {
		let id = sqlite3_column_int64(stmt, 0)
		let path = String(cString: sqlite3_column_text(stmt, 1))
		let size = sqlite3_column_int64(stmt, 2)
		let mtime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
		let hash = String(cString: sqlite3_column_text(stmt, 4))
		let algorithm = String(cString: sqlite3_column_text(stmt, 5))
		let firstSeen = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
		let lastVerified = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
		let lastModifiedRaw = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8)
		let lastModified = lastModifiedRaw.map { Date(timeIntervalSince1970: $0) }
		let statusStr = String(cString: sqlite3_column_text(stmt, 9))
		let status = FileStatus(rawValue: statusStr) ?? .ok

		return FileRecord(
			id: id,
			path: path,
			size: size,
			mtime: mtime,
			hash: hash,
			hashAlgorithm: algorithm,
			firstSeen: firstSeen,
			lastVerified: lastVerified,
			lastModified: lastModified,
			status: status
		)
	}

	// ============================================================================
	private func extractScanResult(from stmt: OpaquePointer) -> ScanResult {
		let id = sqlite3_column_int64(stmt, 0)
		let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
		let completedAtRaw = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
		let completedAt = completedAtRaw.map { Date(timeIntervalSince1970: $0) }
		let walked	 = Int(sqlite3_column_int(stmt, 3))
		let skipped	 = Int(sqlite3_column_int(stmt, 4))
		let new		 = Int(sqlite3_column_int(stmt, 5))
		let modified = Int(sqlite3_column_int(stmt, 6))
		let verified = Int(sqlite3_column_int(stmt, 7))
		let corrupted = Int(sqlite3_column_int(stmt, 8))
		let missing	 = Int(sqlite3_column_int(stmt, 9))
		let upgraded = Int(sqlite3_column_int(stmt, 10))
		let statusStr = String(cString: sqlite3_column_text(stmt, 11))
		let status = ScanStatus(rawValue: statusStr) ?? .completed

		return ScanResult(
			id: id,
			startedAt: startedAt,
			completedAt: completedAt,
			filesWalked: walked,
			filesSkipped: skipped,
			filesNew: new,
			filesModified: modified,
			filesVerified: verified,
			filesCorrupted: corrupted,
			filesMissing: missing,
			filesUpgraded: upgraded,
			status: status
		)
	}

	// MARK: - Binding helpers

	// ============================================================================
	private func bindOptionalText(
		_ stmt: OpaquePointer,
		index: Int32,
		value: String?
	) {
		if let value = value {
			sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
		} else {
			sqlite3_bind_null(stmt, index)
		}
	}

	// ============================================================================
	private func bindOptionalDouble(
		_ stmt: OpaquePointer,
		index: Int32,
		value: Double?
	) {
		if let value = value {
			sqlite3_bind_double(stmt, index, value)
		} else {
			sqlite3_bind_null(stmt, index)
		}
	}

	// ============================================================================
	private func dbError() -> String {
		guard let db = db else { return "database not open" }
		return String(cString: sqlite3_errmsg(db))
	}
}

// MARK: - SQLITE_TRANSIENT shim
// sqlite3_bind_text requires SQLITE_TRANSIENT as a destructor pointer.
// In Swift, this must be expressed as an unsafeBitCast.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
