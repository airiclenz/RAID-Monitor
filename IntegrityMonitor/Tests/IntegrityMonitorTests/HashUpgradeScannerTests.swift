import XCTest
@testable import IntegrityMonitor
import Foundation

/// Tests for HashUpgradeScanner — specifically the critical verify-before-upgrade
/// invariant: a corrupted file must never receive a "clean" new hash.
final class HashUpgradeScannerTests: XCTestCase {

    private var tempDir: URL!
    private var store: SQLiteManifestStore!
    private var logger: Logger!
    private var alertManager: AlertManager!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpgradeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbURL = tempDir.appendingPathComponent("test.db")
        store = SQLiteManifestStore(path: dbURL)
        try! store.open()

        let logURL = tempDir.appendingPathComponent("test.log")
        logger = Logger(path: logURL, level: .debug)
        alertManager = AlertManager(channels: [], config: NotificationConfig(), logger: logger)
    }

    override func tearDown() {
        store.close()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeFile(_ name: String, content: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! content.data(using: .utf8)!.write(to: url)
        return url
    }

    private func sha256(of string: String) throws -> String {
        let url = writeFile("temp_\(UUID().uuidString).txt", content: string)
        let hash = try SHA256Hasher().hash(fileAt: url)
        try? FileManager.default.removeItem(at: url)
        return hash
    }

    // MARK: - Tests

    /// Basic upgrade: a clean file should be upgraded from sha256 → sha256
    /// (same algorithm, just exercises the verify-then-upgrade path).
    func testUpgrade_cleanFile_succeeds() async throws {
        let content = "clean file content"
        let url = writeFile("clean.txt", content: content)
        let correctHash = try sha256(of: content)
        let now = Date()

        try store.upsert(FileRecord(
            path: url.path, size: Int64(content.utf8.count), mtime: now,
            hash: correctHash, hashAlgorithm: "sha256",
            firstSeen: now, lastVerified: now, status: .ok
        ))

        let upgrader = HashUpgradeScanner(store: store, alertManager: alertManager, logger: logger)
        // Upgrade from sha256 → sha256 (same alg — still exercises the code path)
        let result = try await upgrader.upgrade(from: "sha256", to: "sha256")

        XCTAssertEqual(result.upgraded, 1)
        XCTAssertEqual(result.corrupted, 0)
        XCTAssertEqual(result.skipped, 0)
    }

    /// Corruption detection: if stored hash doesn't match current content,
    /// the file must be marked corrupted and NOT upgraded.
    func testUpgrade_corruptedFile_markedCorruptedNotUpgraded() async throws {
        let url = writeFile("corrupted.txt", content: "original content")
        let now = Date()

        // Store a WRONG hash (simulating stored-hash mismatch = corruption)
        try store.upsert(FileRecord(
            path: url.path, size: Int64("original content".utf8.count), mtime: now,
            hash: "0000000000000000000000000000000000000000000000000000000000000000",
            hashAlgorithm: "sha256",
            firstSeen: now, lastVerified: now, status: .ok
        ))

        let upgrader = HashUpgradeScanner(store: store, alertManager: alertManager, logger: logger)
        let result = try await upgrader.upgrade(from: "sha256", to: "sha256")

        XCTAssertEqual(result.corrupted, 1)
        XCTAssertEqual(result.upgraded, 0)

        // Verify the record was marked as corrupted in the database
        let record = try store.record(for: url.path)
        XCTAssertEqual(record?.status, .corrupted)
        // The hash must NOT be updated — still the original wrong hash
        XCTAssertEqual(record?.hash, "0000000000000000000000000000000000000000000000000000000000000000")
    }

    /// Missing file is skipped (not counted as corrupted).
    func testUpgrade_missingFile_skipped() async throws {
        let missingPath = tempDir.appendingPathComponent("does-not-exist.txt").path
        let now = Date()

        try store.upsert(FileRecord(
            path: missingPath, size: 100, mtime: now,
            hash: "abc", hashAlgorithm: "sha256",
            firstSeen: now, lastVerified: now, status: .ok
        ))

        let upgrader = HashUpgradeScanner(store: store, alertManager: alertManager, logger: logger)
        let result = try await upgrader.upgrade(from: "sha256", to: "sha256")

        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.corrupted, 0)
        XCTAssertEqual(result.upgraded, 0)
    }

    /// Already-upgraded records (different algorithm) are not included in candidates.
    func testUpgrade_alreadyUpgradedRecordsSkipped() async throws {
        let url = writeFile("file.txt", content: "test")
        let hash = try sha256(of: "test")
        let now = Date()

        // This record uses "sha256" — will be included
        try store.upsert(FileRecord(
            path: url.path, size: 4, mtime: now,
            hash: hash, hashAlgorithm: "sha256",
            firstSeen: now, lastVerified: now, status: .ok
        ))

        // Upgrade once
        let upgrader = HashUpgradeScanner(store: store, alertManager: alertManager, logger: logger)
        let result1 = try await upgrader.upgrade(from: "sha256", to: "sha256")
        XCTAssertEqual(result1.upgraded, 1)

        // Upgrade again with from="nonexistent-alg" — nothing to upgrade
        let result2 = try await upgrader.upgrade(from: "blake3", to: "sha256")
        XCTAssertEqual(result2.upgraded, 0)
        XCTAssertEqual(result2.skipped, 0)
        XCTAssertEqual(result2.corrupted, 0)
    }
}
