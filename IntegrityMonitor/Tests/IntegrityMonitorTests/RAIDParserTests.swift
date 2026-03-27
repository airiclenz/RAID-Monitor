import XCTest
@testable import IntegrityMonitor

final class RAIDParserTests: XCTestCase {

    // MARK: - Fixtures

    static let onlineRAIDOutput = """
    AppleRAID sets (1 found)

    ===============================================================================
    Name:          G-Raid
    Unique ID:     F71DAB1B-A18D-434D-B275-9A82BB3D1483
    Type:          Mirror
    Status:        Online
    Size:          3.64 TB (4,000,443,039,744 Bytes)
    Share:         No
    Stripe Size:   N/A
    I/O Size:      512 Bytes
    Chunk Count:   N/A
    Recovery:      none
    Bitmap:        None
    Rebuild:       manual
    Device Node:   disk4
    -------------------------------------------------------------------------------
    #  DevNode   UUID                                  Status      Size
    -------------------------------------------------------------------------------
    0  disk8s2   AAAAAAAA-0000-0000-0000-000000000001  Online      3.64 TB (4000443039744 Bytes)
    1  disk9s2   AAAAAAAA-0000-0000-0000-000000000002  Online      3.64 TB (4000443039744 Bytes)
    ===============================================================================
    """

    static let degradedRAIDOutput = """
    AppleRAID sets (1 found)

    ===============================================================================
    Name:          G-Raid
    Unique ID:     F71DAB1B-A18D-434D-B275-9A82BB3D1483
    Type:          Mirror
    Status:        Degraded
    Size:          3.64 TB (4,000,443,039,744 Bytes)
    Device Node:   disk4
    -------------------------------------------------------------------------------
    #  DevNode   UUID                                  Status      Size
    -------------------------------------------------------------------------------
    0  disk8s2   AAAAAAAA-0000-0000-0000-000000000001  Online      3.64 TB (4000443039744 Bytes)
    1  disk9s2   AAAAAAAA-0000-0000-0000-000000000002  Failed      3.64 TB (4000443039744 Bytes)
    ===============================================================================
    """

    static let rebuildingRAIDOutput = """
    AppleRAID sets (1 found)

    ===============================================================================
    Name:          G-Raid
    Unique ID:     F71DAB1B-A18D-434D-B275-9A82BB3D1483
    Type:          Mirror
    Status:        Rebuilding
    Device Node:   disk4
    -------------------------------------------------------------------------------
    #  DevNode   UUID                                  Status      Size
    -------------------------------------------------------------------------------
    0  disk8s2   AAAAAAAA-0000-0000-0000-000000000001  Online      3.64 TB (4000443039744 Bytes)
    1  disk9s2   AAAAAAAA-0000-0000-0000-000000000002  8% (Rebuilding)  3.64 TB (4000443039744 Bytes)
    ===============================================================================
    """

    static let noArrayOutput = "AppleRAID sets (0 found)\n"

    // MARK: - Tests

    func testParse_onlineArray() {
        let arrays = RAIDOutputParser.parse(RAIDParserTests.onlineRAIDOutput)
        XCTAssertEqual(arrays.count, 1)

        let array = arrays[0]
        XCTAssertEqual(array.name, "G-Raid")
        XCTAssertEqual(array.uuid, "F71DAB1B-A18D-434D-B275-9A82BB3D1483")
        XCTAssertEqual(array.status, "Online")
        XCTAssertTrue(array.isOnline)
        XCTAssertFalse(array.isDegraded)
        XCTAssertFalse(array.isFailed)
        XCTAssertEqual(array.members.count, 2)

        XCTAssertEqual(array.members[0].devNode, "disk8s2")
        XCTAssertEqual(array.members[0].status, "Online")
        XCTAssertEqual(array.members[1].devNode, "disk9s2")
        XCTAssertEqual(array.members[1].status, "Online")
    }

    func testParse_degradedArray() {
        let arrays = RAIDOutputParser.parse(RAIDParserTests.degradedRAIDOutput)
        XCTAssertEqual(arrays.count, 1)

        let array = arrays[0]
        XCTAssertEqual(array.status, "Degraded")
        XCTAssertTrue(array.isDegraded)

        XCTAssertEqual(array.members[0].status, "Online")
        XCTAssertEqual(array.members[1].status, "Failed")
    }

    func testParse_rebuildingMember() {
        let arrays = RAIDOutputParser.parse(RAIDParserTests.rebuildingRAIDOutput)
        XCTAssertEqual(arrays.count, 1)

        // Member 1 has a status with spaces: "8% (Rebuilding)"
        XCTAssertEqual(arrays[0].members[1].devNode, "disk9s2")
        XCTAssertEqual(arrays[0].members[1].status, "8% (Rebuilding)")
    }

    func testParse_noArrays() {
        let arrays = RAIDOutputParser.parse(RAIDParserTests.noArrayOutput)
        XCTAssertTrue(arrays.isEmpty)
    }

    func testParse_emptyOutput() {
        let arrays = RAIDOutputParser.parse("")
        XCTAssertTrue(arrays.isEmpty)
    }

    func testParse_memberDevNodes() {
        let arrays = RAIDOutputParser.parse(RAIDParserTests.onlineRAIDOutput)
        XCTAssertEqual(arrays[0].members[0].devNode, "disk8s2")
        XCTAssertEqual(arrays[0].members[1].devNode, "disk9s2")
    }
}
