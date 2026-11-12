import CoreBluetooth
import XCTest

@testable import DeskKit

final class DiagnosticsTests: XCTestCase {
  func testHexFormatsUppercaseSeparatedBytes() {
    XCTAssertEqual(DeskLog.hex(Data([0x47, 0x00, 0xFF])), "47 00 FF")
    XCTAssertEqual(DeskLog.hex(Data()), "(empty)")
  }

  func testMillisecondsOfDuration() {
    XCTAssertEqual(DeskLog.milliseconds(.milliseconds(1500)), 1500)
    XCTAssertEqual(DeskLog.milliseconds(.seconds(2)), 2000)
    XCTAssertEqual(DeskLog.milliseconds(.microseconds(900)), 0)
  }

  func testSampleDescriptionShowsRawAndMillimetres() {
    let sample = HeightSample(heightRaw: 1100, speedRaw: -380)
    XCTAssertEqual(
      DeskLog.describe(sample, baseMM: 620),
      "height=1100 raw (730.0 mm) speed=-380 raw (-38.0 mm/s)")
  }

  func testHoldVariantLabels() {
    XCTAssertEqual(HoldVariant(label: "a"), .targetLimit)
    XCTAssertEqual(HoldVariant(label: " B "), .commandPulses)
    XCTAssertEqual(HoldVariant(label: "C"), .directionSentinel)
    XCTAssertNil(HoldVariant(label: "D"))
    XCTAssertNil(HoldVariant(label: ""))
    for variant in [HoldVariant.targetLimit, .commandPulses, .directionSentinel] {
      XCTAssertEqual(HoldVariant(label: variant.label), variant)
    }
  }

  func testHardwareOptionsDefaultsAreUnchanged() throws {
    let suite = "DiagnosticsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(HardwareOptions(defaults: defaults), HardwareOptions())
    XCTAssertEqual(HardwareOptions().holdVariant, .targetLimit)
    XCTAssertFalse(HardwareOptions().patchesUserID)
  }

  func testHardwareOptionsReadUserDefaults() throws {
    let suite = "DiagnosticsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("c", forKey: HardwareOptions.holdVariantKey)
    defaults.set(true, forKey: HardwareOptions.patchUserIDKey)
    let options = HardwareOptions(defaults: defaults)
    XCTAssertEqual(options.holdVariant, .directionSentinel)
    XCTAssertTrue(options.patchesUserID)

    defaults.set("nonsense", forKey: HardwareOptions.holdVariantKey)
    XCTAssertEqual(HardwareOptions(defaults: defaults).holdVariant, .targetLimit)
  }

  func testPropertyNames() {
    XCTAssertEqual(
      CoreBluetoothNames.properties([.writeWithoutResponse, .write]),
      "0x0C [writeWithoutResponse, write]")
    XCTAssertEqual(CoreBluetoothNames.properties([.read, .notify]), "0x12 [read, notify]")
  }

  func testErrorNamesIncludeDomainCodeAndName() {
    let att = NSError(
      domain: CBATTError.errorDomain, code: CBATTError.insufficientAuthentication.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "Authentication is insufficient."])
    XCTAssertEqual(
      CoreBluetoothNames.error(att),
      "CBATTErrorDomain#5 insufficientAuthentication \"Authentication is insufficient.\"")
    let cb = NSError(
      domain: CBError.errorDomain, code: CBError.peerRemovedPairingInformation.rawValue)
    XCTAssertTrue(CoreBluetoothNames.error(cb).contains("peerRemovedPairingInformation"))
    XCTAssertEqual(CoreBluetoothNames.error(nil as (any Error)?), "none")
  }
}
