import XCTest

@testable import DeskKit

final class DPGTests: XCTestCase {
  func testReadFrames() {
    XCTAssertEqual(DPG.readFrame(.capabilities), Data([0x7F, 0x80, 0x00]))
    XCTAssertEqual(DPG.readFrame(.baseOffset), Data([0x7F, 0x81, 0x00]))
    XCTAssertEqual(DPG.readFrame(.userID), Data([0x7F, 0x86, 0x00]))
  }

  func testWriteFrame() {
    XCTAssertEqual(
      DPG.writeFrame(.userID, data: Data([0x01, 0xAA, 0xBB])),
      Data([0x7F, 0x86, 0x80, 0x01, 0xAA, 0xBB]))
    XCTAssertEqual(DPG.writeFrame(.baseOffset, data: Data()), Data([0x7F, 0x81, 0x80]))
  }

  func testParsesBaseOffset() {
    let response = Data([0x01, 0x81, 0x80, 0x38, 0x18])
    XCTAssertEqual(DPG.parseBaseOffsetMM(response), 620.0)
  }

  func testParsesBaseOffsetWithFraction() {
    let response = Data([0x01, 0x81, 0x80, 0x0B, 0x18])
    XCTAssertEqual(DPG.parseBaseOffsetMM(response), 615.5)
  }

  func testParsesBaseOffsetIgnoresTrailingBytes() {
    let response = Data([0x01, 0x81, 0x80, 0x38, 0x18, 0x00, 0x00])
    XCTAssertEqual(DPG.parseBaseOffsetMM(response), 620.0)
  }

  func testParsesBaseOffsetFromDataSlice() {
    let backing = Data([0xFF, 0x01, 0x81, 0x80, 0x38, 0x18])
    XCTAssertEqual(DPG.parseBaseOffsetMM(backing[1...]), 620.0)
  }

  func testRejectsInvalidBaseOffset() {
    XCTAssertNil(DPG.parseBaseOffsetMM(Data([0x00, 0x81, 0x80, 0x38, 0x18])))
    XCTAssertNil(DPG.parseBaseOffsetMM(Data([0x02, 0x81, 0x80, 0x38, 0x18])))
    XCTAssertNil(DPG.parseBaseOffsetMM(Data([0x01, 0x81, 0x80, 0x38])))
    XCTAssertNil(DPG.parseBaseOffsetMM(Data()))
  }

  func testPayloadStripsHeader() {
    XCTAssertEqual(DPG.payload(of: Data([0x01, 0x86, 0x80, 0xAA, 0xBB])), Data([0xAA, 0xBB]))
    XCTAssertEqual(DPG.payload(of: Data([0x01, 0x86, 0x80])), Data())
    XCTAssertEqual(DPG.payload(of: Data([0xFF, 0x01, 0x86, 0x80, 0xAA])[1...]), Data([0xAA]))
  }

  func testPayloadRejectsInvalidResponses() {
    XCTAssertNil(DPG.payload(of: Data([0x00, 0x86, 0x80, 0xAA])))
    XCTAssertNil(DPG.payload(of: Data([0x01, 0x86])))
    XCTAssertNil(DPG.payload(of: Data()))
  }

  func testUserIDAlreadySetNeedsNoPatch() {
    XCTAssertNil(DPG.userIDPatchFrame(response: Data([0x01, 0x86, 0x80, 0x01, 0x02, 0x03])))
  }

  func testUserIDPatch() {
    let response = Data([0x01, 0x86, 0x80, 0x00, 0x02, 0x03, 0x04])
    XCTAssertEqual(
      DPG.userIDPatchFrame(response: response),
      Data([0x7F, 0x86, 0x80, 0x01, 0x02, 0x03, 0x04]))
  }

  func testUserIDPatchKeepsAll17PayloadBytes() {
    let payload = Data([0x00]) + Data(repeating: 0xAB, count: 16)
    let frame = DPG.userIDPatchFrame(response: Data([0x01, 0x86, 0x80]) + payload)
    XCTAssertEqual(frame?.count, 20)
    XCTAssertEqual(frame?.prefix(4), Data([0x7F, 0x86, 0x80, 0x01]))
    XCTAssertEqual(frame?.dropFirst(4), Data(repeating: 0xAB, count: 16))
  }

  func testUserIDPatchFromDataSlice() {
    let backing = Data([0xEE, 0x01, 0x86, 0x80, 0x00, 0x05])
    XCTAssertEqual(
      DPG.userIDPatchFrame(response: backing[1...]),
      Data([0x7F, 0x86, 0x80, 0x01, 0x05]))
  }

  func testUserIDPatchIgnoresInvalidOrEmptyResponses() {
    XCTAssertNil(DPG.userIDPatchFrame(response: Data([0x00, 0x86, 0x80, 0x00, 0x05])))
    XCTAssertNil(DPG.userIDPatchFrame(response: Data([0x01, 0x86, 0x80])))
    XCTAssertNil(DPG.userIDPatchFrame(response: Data()))
  }
}
