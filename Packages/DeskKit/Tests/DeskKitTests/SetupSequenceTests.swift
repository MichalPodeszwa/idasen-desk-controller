import XCTest

@testable import DeskKit

final class SetupSequenceTests: XCTestCase {
  private let valid: [GattCharacteristic: GattProperties] = [
    .control: [.write, .writeWithoutResponse],
    .referenceInput: [.write, .writeWithoutResponse, .read],
    .referenceOutput: [.read, .notify],
    .dpg: [.write, .notify, .read],
  ]

  private func baseOffsetResponse(tenths: UInt16) -> Data {
    Data([0x01, 0x81, 0x00, UInt8(tenths & 0xFF), UInt8(tenths >> 8)])
  }

  private func reachDPG(_ sequence: inout SetupSequence) -> SetupSequence.Command {
    XCTAssertEqual(sequence.start(), .discoverServices)
    XCTAssertEqual(sequence.servicesDiscovered(), .discoverCharacteristics)
    XCTAssertEqual(sequence.characteristicsDiscovered(valid), .enableNotify(.referenceOutput))
    XCTAssertEqual(sequence.notifyEnabled(), .enableNotify(.dpg))
    return sequence.notifyEnabled()
  }

  func testPropertyRequirementsMatchProtocolDoc() {
    XCTAssertEqual(GattCharacteristic.control.requiredProperties.rawValue, 0x0c)
    XCTAssertEqual(GattCharacteristic.referenceInput.requiredProperties.rawValue, 0x0c)
  }

  func testHappyPathReadsBaseOffsetAndFinishes() {
    var sequence = SetupSequence()
    XCTAssertEqual(
      reachDPG(&sequence), .writeDPG(Data([0x7F, 0x81, 0x00]), expectsResponse: true))
    XCTAssertEqual(
      sequence.dpgResponse(baseOffsetResponse(tenths: 6150)), .finish(baseOffsetMM: 615))
    XCTAssertEqual(sequence.step, .finished)
  }

  func testInvalidBaseOffsetResponseFallsBackToNil() {
    var sequence = SetupSequence()
    _ = reachDPG(&sequence)
    XCTAssertEqual(
      sequence.dpgResponse(Data([0x00, 0x81, 0x00, 0x16, 0x18])), .finish(baseOffsetMM: nil))
  }

  func testTimeoutFallsBackToNil() {
    var sequence = SetupSequence()
    _ = reachDPG(&sequence)
    XCTAssertEqual(sequence.dpgUnavailable(), .finish(baseOffsetMM: nil))
    XCTAssertNil(sequence.dpgUnavailable())
    XCTAssertNil(sequence.dpgResponse(baseOffsetResponse(tenths: 6200)))
  }

  func testUserIDPatchWhenFlagSetAndFirstByteNotValid() {
    var sequence = SetupSequence(patchesUserID: true)
    _ = reachDPG(&sequence)
    XCTAssertEqual(
      sequence.dpgResponse(baseOffsetResponse(tenths: 6200)),
      .writeDPG(Data([0x7F, 0x86, 0x00]), expectsResponse: true))
    let userID = Data([0x01, 0x86, 0x00, 0x00, 0xAA, 0xBB])
    XCTAssertEqual(
      sequence.dpgResponse(userID),
      .writeDPG(Data([0x7F, 0x86, 0x80, 0x01, 0xAA, 0xBB]), expectsResponse: false))
    XCTAssertEqual(sequence.writeCompleted(), .finish(baseOffsetMM: 620))
  }

  func testUserIDLeftAloneWhenAlreadySet() {
    var sequence = SetupSequence(patchesUserID: true)
    _ = reachDPG(&sequence)
    _ = sequence.dpgResponse(baseOffsetResponse(tenths: 6200))
    XCTAssertEqual(
      sequence.dpgResponse(Data([0x01, 0x86, 0x00, 0x01, 0xAA])), .finish(baseOffsetMM: 620))
  }

  func testUserIDTimeoutStillKeepsBaseOffset() {
    var sequence = SetupSequence(patchesUserID: true)
    _ = reachDPG(&sequence)
    _ = sequence.dpgResponse(baseOffsetResponse(tenths: 6150))
    XCTAssertEqual(sequence.dpgUnavailable(), .finish(baseOffsetMM: 615))
  }

  func testNoUserIDTrafficWithoutFlag() {
    var sequence = SetupSequence()
    _ = reachDPG(&sequence)
    XCTAssertEqual(
      sequence.dpgResponse(baseOffsetResponse(tenths: 6200)), .finish(baseOffsetMM: 620))
  }

  func testMissingCharacteristicIsAnError() {
    var sequence = SetupSequence()
    _ = sequence.start()
    _ = sequence.servicesDiscovered()
    var found = valid
    found[.referenceOutput] = nil
    guard case .fail(let message) = sequence.characteristicsDiscovered(found) else {
      return XCTFail("expected failure")
    }
    XCTAssertTrue(message.contains("reference output"))
    XCTAssertEqual(sequence.step, .failed)
  }

  func testPropertyMismatchIsAnError() {
    for broken in [GattCharacteristic.control, .referenceInput, .referenceOutput, .dpg] {
      var sequence = SetupSequence()
      _ = sequence.start()
      _ = sequence.servicesDiscovered()
      var found = valid
      found[broken] = [.read]
      guard case .fail(let message) = sequence.characteristicsDiscovered(found) else {
        return XCTFail("expected failure for \(broken)")
      }
      XCTAssertTrue(message.contains(broken.label))
    }
  }

  func testWriteWithoutResponseAloneIsNotEnoughForControl() {
    var sequence = SetupSequence()
    _ = sequence.start()
    _ = sequence.servicesDiscovered()
    var found = valid
    found[.control] = [.writeWithoutResponse]
    guard case .fail = sequence.characteristicsDiscovered(found) else {
      return XCTFail("expected failure")
    }
  }

  func testUnexpectedDPGTrafficIsIgnoredOutsideItsSteps() {
    var sequence = SetupSequence()
    XCTAssertNil(sequence.dpgResponse(baseOffsetResponse(tenths: 6200)))
    XCTAssertNil(sequence.writeCompleted())
    XCTAssertFalse(sequence.isWaitingForDPGResponse)
  }
}
