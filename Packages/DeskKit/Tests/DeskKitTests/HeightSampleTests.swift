import XCTest

@testable import DeskKit

final class HeightSampleTests: XCTestCase {
  func testDecodesHeightAndPositiveSpeed() throws {
    let sample = try HeightSample(decoding: Data([0x4C, 0x04, 0x20, 0x01]))
    XCTAssertEqual(sample.heightRaw, 1100)
    XCTAssertEqual(sample.speedRaw, 288)
    XCTAssertEqual(sample.speedMMPerSecond, 28.8, accuracy: 1e-9)
    XCTAssertEqual(sample.height.raw, 1100)
    XCTAssertFalse(sample.isStationary)
  }

  func testDecodesNegativeSpeed() throws {
    let sample = try HeightSample(decoding: Data([0x00, 0x00, 0xE0, 0xFE]))
    XCTAssertEqual(sample.speedRaw, -288)
    XCTAssertEqual(sample.speedMMPerSecond, -28.8, accuracy: 1e-9)
  }

  func testDecodesStationary() throws {
    let sample = try HeightSample(decoding: Data([0x88, 0x13, 0x00, 0x00]))
    XCTAssertEqual(sample.heightRaw, 5000)
    XCTAssertTrue(sample.isStationary)
  }

  func testDecodesExtremes() throws {
    let sample = try HeightSample(decoding: Data([0xFF, 0xFF, 0x00, 0x80]))
    XCTAssertEqual(sample.heightRaw, 65535)
    XCTAssertEqual(sample.speedRaw, -32768)
    XCTAssertEqual(sample.height.raw, 6500)
  }

  func testDecodesFromDataSlice() throws {
    let backing = Data([0xAA, 0xBB, 0x4C, 0x04, 0x20, 0x01, 0xCC])
    let sample = try HeightSample(decoding: backing[2..<6])
    XCTAssertEqual(sample, HeightSample(heightRaw: 1100, speedRaw: 288))
  }

  func testRejectsWrongLengths() {
    for length in [0, 1, 2, 3, 5, 8] {
      XCTAssertThrowsError(try HeightSample(decoding: Data(repeating: 0, count: length))) {
        XCTAssertEqual($0 as? HeightSampleError, .invalidLength(length))
      }
    }
  }
}
