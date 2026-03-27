import XCTest
@testable import IntegrityMonitor

final class ExclusionRulesTests: XCTestCase {

    // MARK: - Directory patterns

    func testDescendAllowed_noPatterns() {
        let rules = ExclusionRules(config: ExclusionConfig())
        let url = URL(fileURLWithPath: "/some/path/Photos")
        XCTAssertTrue(rules.shouldDescend(into: url))
    }

    func testDescendBlocked_exactMatch() {
        let rules = ExclusionRules(config: ExclusionConfig(
            directoryPatterns: ["Lightroom Previews.lrdata"]
        ))
        let url = URL(fileURLWithPath: "/RAID/Photos/Lightroom Previews.lrdata")
        XCTAssertFalse(rules.shouldDescend(into: url))
    }

    func testDescendBlocked_globPattern() {
        let rules = ExclusionRules(config: ExclusionConfig(
            directoryPatterns: ["*.lrdata"]
        ))
        XCTAssertFalse(rules.shouldDescend(into: URL(fileURLWithPath: "/RAID/Photos/Catalog.lrdata")))
        XCTAssertTrue(rules.shouldDescend(into: URL(fileURLWithPath: "/RAID/Photos/Catalog.lrcat")))
    }

    func testDescendBlocked_caseInsensitive() {
        let rules = ExclusionRules(config: ExclusionConfig(
            directoryPatterns: ["*.lrdata"]
        ))
        XCTAssertFalse(rules.shouldDescend(into: URL(fileURLWithPath: "/RAID/Photos/Catalog.LRDATA")))
    }

    func testDescendAllowed_unmatchedPattern() {
        let rules = ExclusionRules(config: ExclusionConfig(
            directoryPatterns: ["*.cache"]
        ))
        XCTAssertTrue(rules.shouldDescend(into: URL(fileURLWithPath: "/RAID/Photos/2024")))
    }

    // MARK: - Path patterns

    func testInclude_noPatterns() {
        let rules = ExclusionRules(config: ExclusionConfig())
        let url = URL(fileURLWithPath: "/RAID/Photos/image.jpg")
        XCTAssertTrue(rules.shouldInclude(fileAt: url, size: 1024))
    }

    func testExclude_exactFilename() {
        let rules = ExclusionRules(config: ExclusionConfig(
            pathPatterns: [".DS_Store"]
        ))
        XCTAssertFalse(rules.shouldInclude(
            fileAt: URL(fileURLWithPath: "/RAID/Photos/.DS_Store"),
            size: 6148
        ))
    }

    func testExclude_globPattern() {
        let rules = ExclusionRules(config: ExclusionConfig(
            pathPatterns: ["*.tmp"]
        ))
        XCTAssertFalse(rules.shouldInclude(
            fileAt: URL(fileURLWithPath: "/RAID/work/export.tmp"),
            size: 100
        ))
        XCTAssertTrue(rules.shouldInclude(
            fileAt: URL(fileURLWithPath: "/RAID/work/final.jpg"),
            size: 100
        ))
    }

    func testExclude_caseInsensitive() {
        let rules = ExclusionRules(config: ExclusionConfig(
            pathPatterns: ["*.tmp"]
        ))
        XCTAssertFalse(rules.shouldInclude(
            fileAt: URL(fileURLWithPath: "/RAID/work/export.TMP"),
            size: 100
        ))
    }

    // MARK: - Size bounds

    func testExclude_belowMinSize() {
        let rules = ExclusionRules(config: ExclusionConfig(minSizeBytes: 1024))
        XCTAssertFalse(rules.shouldInclude(
            fileAt: URL(fileURLWithPath: "/RAID/file.txt"),
            size: 512
        ))
    }

    func testInclude_atMinSize() {
        let rules = ExclusionRules(config: ExclusionConfig(minSizeBytes: 1024))
        XCTAssertTrue(rules.shouldInclude(
            fileAt: URL(fileURLWithPath: "/RAID/file.txt"),
            size: 1024
        ))
    }

    func testExclude_aboveMaxSize() {
        let rules = ExclusionRules(config: ExclusionConfig(maxSizeBytes: 100 * 1024 * 1024))
        XCTAssertFalse(rules.shouldInclude(
            fileAt: URL(fileURLWithPath: "/RAID/bigfile.mov"),
            size: 200 * 1024 * 1024
        ))
    }

    func testInclude_withinSizeBounds() {
        let rules = ExclusionRules(config: ExclusionConfig(
            minSizeBytes: 100,
            maxSizeBytes: 100 * 1024 * 1024
        ))
        XCTAssertTrue(rules.shouldInclude(
            fileAt: URL(fileURLWithPath: "/RAID/file.jpg"),
            size: 1024 * 1024
        ))
    }
}
