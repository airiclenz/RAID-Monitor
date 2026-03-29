import XCTest
@testable import IntegrityMonitor
import Foundation

final class SHA256HasherTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SHA256HasherTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // SHA-256 of empty string: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    func testHash_emptyFile() throws {
        let file = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: file)

        let hasher = SHA256Hasher()
        let digest = try hasher.hash(fileAt: file)
        XCTAssertEqual(digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // SHA-256 of "hello\n" (5 bytes + newline): 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
    func testHash_knownContent() throws {
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello\n".data(using: .utf8)!.write(to: file)

        let hasher = SHA256Hasher()
        let digest = try hasher.hash(fileAt: file)
        XCTAssertEqual(digest, "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    func testHash_deterministicForSameContent() throws {
        let file = tempDir.appendingPathComponent("test.bin")
        let data = Data(repeating: 0xAB, count: 1024)
        try data.write(to: file)

        let hasher = SHA256Hasher()
        let d1 = try hasher.hash(fileAt: file)
        let d2 = try hasher.hash(fileAt: file)
        XCTAssertEqual(d1, d2)
    }

    func testHash_differentForDifferentContent() throws {
        let file1 = tempDir.appendingPathComponent("a.bin")
        let file2 = tempDir.appendingPathComponent("b.bin")
        try Data(repeating: 0xAA, count: 512).write(to: file1)
        try Data(repeating: 0xBB, count: 512).write(to: file2)

        let hasher = SHA256Hasher()
        let d1 = try hasher.hash(fileAt: file1)
        let d2 = try hasher.hash(fileAt: file2)
        XCTAssertNotEqual(d1, d2)
    }

    func testHash_multiChunkFile() throws {
        // Write a file larger than the 4MB chunk size to exercise the streaming path
        let file = tempDir.appendingPathComponent("large.bin")
        let chunkCount = 5
        let data = Data(repeating: 0x42, count: chunkCount * 4 * 1024 * 1024 + 100)
        try data.write(to: file)

        let hasher = SHA256Hasher()
        let digest = try hasher.hash(fileAt: file)
        XCTAssertEqual(digest.count, 64)  // 256 bits = 32 bytes = 64 hex chars
    }

    func testHash_outputIsHex() throws {
        let file = tempDir.appendingPathComponent("hex.txt")
        try "test".data(using: .utf8)!.write(to: file)

        let hasher = SHA256Hasher()
        let digest = try hasher.hash(fileAt: file)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testHash_throwsOnMissingFile() {
        let missing = tempDir.appendingPathComponent("does-not-exist.txt")
        let hasher = SHA256Hasher()
        XCTAssertThrowsError(try hasher.hash(fileAt: missing))
    }

    func testHasherFactory_sha256() throws {
        let hasher = try HasherFactory.make(for: "sha256")
        XCTAssertEqual(hasher.algorithmName, "sha256")
    }

    func testHasherFactory_unknownAlgorithm() {
        XCTAssertThrowsError(try HasherFactory.make(for: "md5")) { error in
            guard case AppError.unsupportedHashAlgorithm(let name) = error else {
                XCTFail("Expected unsupportedHashAlgorithm error, got \(error)")
                return
            }
            XCTAssertEqual(name, "md5")
        }
    }
}
