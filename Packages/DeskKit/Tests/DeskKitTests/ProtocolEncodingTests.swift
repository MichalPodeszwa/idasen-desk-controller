import XCTest

@testable import DeskKit

final class ProtocolEncodingTests: XCTestCase {
  func testUUIDs() {
    XCTAssertEqual(DeskUUID.controlService, "99FA0001-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.control, "99FA0002-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.error, "99FA0003-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.dpgService, "99FA0010-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.dpg, "99FA0011-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.referenceOutputService, "99FA0020-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.referenceOutput, "99FA0021-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.referenceInputService, "99FA0030-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.referenceInput, "99FA0031-338A-1024-8A49-009C0215F78A")
    XCTAssertEqual(DeskUUID.advertisedService, DeskUUID.controlService)
  }

  func testUUIDsAreValid() {
    let all = [
      DeskUUID.controlService, DeskUUID.control, DeskUUID.error, DeskUUID.dpgService,
      DeskUUID.dpg, DeskUUID.referenceOutputService, DeskUUID.referenceOutput,
      DeskUUID.referenceInputService, DeskUUID.referenceInput,
    ]
    for string in all {
      XCTAssertNotNil(UUID(uuidString: string), string)
      XCTAssertEqual(string, string.uppercased())
    }
  }

  func testCommandBytes() {
    XCTAssertEqual(DeskCommand.up.bytes, Data([0x47, 0x00]))
    XCTAssertEqual(DeskCommand.down.bytes, Data([0x46, 0x00]))
    XCTAssertEqual(DeskCommand.stop.bytes, Data([0xFF, 0x00]))
    XCTAssertEqual(DeskCommand.wake.bytes, Data([0xFE, 0x00]))
  }

  func testReferenceInputTarget() {
    XCTAssertEqual(ReferenceInput.target(DeskHeight(clamping: 0)), Data([0x00, 0x00]))
    XCTAssertEqual(ReferenceInput.target(DeskHeight(clamping: 1100)), Data([0x4C, 0x04]))
    XCTAssertEqual(ReferenceInput.target(DeskHeight(clamping: 5000)), Data([0x88, 0x13]))
    XCTAssertEqual(ReferenceInput.target(DeskHeight(clamping: 6500)), Data([0x64, 0x19]))
    XCTAssertEqual(ReferenceInput.target(DeskHeight(clamping: 99999)), Data([0x64, 0x19]))
  }

  func testReferenceInputSentinels() {
    XCTAssertEqual(ReferenceInput.stop, Data([0x01, 0x80]))
    XCTAssertEqual(ReferenceInput.directionUp, Data([0x00, 0x80]))
    XCTAssertEqual(ReferenceInput.directionDown, Data([0xFF, 0x7F]))
  }

  func testSentinelsAreOutsideValidTargets() {
    for sentinel in [ReferenceInput.stop, ReferenceInput.directionUp, ReferenceInput.directionDown]
    {
      let value = Int16(bitPattern: UInt16(sentinel[0]) | UInt16(sentinel[1]) << 8)
      XCTAssertFalse(DeskHeight.range.contains(Int(value)))
    }
  }
}
