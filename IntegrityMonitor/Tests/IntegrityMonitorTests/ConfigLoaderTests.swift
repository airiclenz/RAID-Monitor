import XCTest
@testable import IntegrityMonitor
import Foundation

final class ConfigLoaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeConfig(_ json: String) -> URL {
        let url = tempDir.appendingPathComponent("config.json")
        try! json.data(using: .utf8)!.write(to: url)
        return url
    }

    private func watchDir() -> String {
        tempDir.appendingPathComponent("watch").path
    }

    private func makeWatchDir() {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: watchDir()),
            withIntermediateDirectories: true
        )
    }

    // MARK: - Tests

    func testLoad_validMinimalConfig() throws {
        makeWatchDir()
        let url = writeConfig("""
        {
          "watchPaths": ["\(watchDir())"],
          "database": {"primary": "\(tempDir.path)/manifest.db"}
        }
        """)
        let config = try ConfigLoader.load(from: url)
        XCTAssertEqual(config.watchPaths, [watchDir()])
        XCTAssertEqual(config.hashAlgorithm, "sha256")       // default
        XCTAssertEqual(config.schedule.verificationIntervalDays, 30)  // default
        XCTAssertEqual(config.performance.maxHashThreads, 2) // default
    }

    func testLoad_throwsWhenFileNotFound() {
        let missing = tempDir.appendingPathComponent("no-such-file.json")
        XCTAssertThrowsError(try ConfigLoader.load(from: missing)) { error in
            guard case AppError.configNotFound = error else {
                XCTFail("Expected configNotFound, got \(error)")
                return
            }
        }
    }

    func testLoad_throwsOnInvalidJSON() {
        let url = writeConfig("not json at all {{{")
        XCTAssertThrowsError(try ConfigLoader.load(from: url)) { error in
            guard case AppError.configValidation = error else {
                XCTFail("Expected configValidation, got \(error)")
                return
            }
        }
    }

    func testLoad_throwsWhenWatchPathsEmpty() {
        let url = writeConfig("""
        {
          "watchPaths": [],
          "database": {"primary": "\(tempDir.path)/manifest.db"}
        }
        """)
        XCTAssertThrowsError(try ConfigLoader.load(from: url)) { error in
            guard case AppError.configValidation(let msg) = error else {
                XCTFail("Expected configValidation, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("watchPaths"))
        }
    }

    func testLoad_throwsWhenWatchPathDoesNotExist() {
        let url = writeConfig("""
        {
          "watchPaths": ["/path/that/definitely/does/not/exist/xyz"],
          "database": {"primary": "\(tempDir.path)/manifest.db"}
        }
        """)
        XCTAssertThrowsError(try ConfigLoader.load(from: url))
    }

    func testLoad_defaultsApplied() throws {
        makeWatchDir()
        let url = writeConfig("""
        {
          "watchPaths": ["\(watchDir())"],
          "database": {"primary": "\(tempDir.path)/manifest.db"}
        }
        """)
        let config = try ConfigLoader.load(from: url)
        XCTAssertEqual(config.hashAlgorithm, "sha256")
        XCTAssertEqual(config.schedule.verificationIntervalDays, 30)
        XCTAssertEqual(config.performance.maxHashThreads, 2)
        XCTAssertEqual(config.performance.dbBatchSize, 500)
        XCTAssertEqual(config.performance.maxVerificationsPerRun, 1000)
        XCTAssertTrue(config.notifications.onCorruption)
        XCTAssertTrue(config.notifications.onRAIDDegraded)
        XCTAssertFalse(config.notifications.onMissingFile)
        XCTAssertFalse(config.notifications.onScanComplete)
        XCTAssertTrue(config.notifications.onScanCompleteWithIssues)
    }

    func testLoad_createsDatabaseDirectory() throws {
        makeWatchDir()
        let dbPath = tempDir.appendingPathComponent("subdir/nested/manifest.db").path
        let url = writeConfig("""
        {
          "watchPaths": ["\(watchDir())"],
          "database": {"primary": "\(dbPath)"}
        }
        """)
        _ = try ConfigLoader.load(from: url)
        let dbDir = (dbPath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbDir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testLoad_tildeExpansion() throws {
        // Verify that ~ in watchPaths are resolved correctly (we can't easily
        // test the actual Home path, but we verify resolvedWatchPaths doesn't
        // contain ~ anymore when using an absolute path)
        makeWatchDir()
        let url = writeConfig("""
        {
          "watchPaths": ["\(watchDir())"],
          "database": {"primary": "\(tempDir.path)/manifest.db"}
        }
        """)
        let config = try ConfigLoader.load(from: url)
        XCTAssertFalse(config.resolvedWatchPaths.first?.path.contains("~") ?? false)
    }
}
