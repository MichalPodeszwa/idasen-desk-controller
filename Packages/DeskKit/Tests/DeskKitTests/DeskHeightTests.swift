import XCTest

@testable import DeskKit

final class DeskHeightTests: XCTestCase {
  func testRangeBounds() {
    XCTAssertEqual(DeskHeight.range, 0...6500)
  }

  func testClamping() {
    XCTAssertEqual(DeskHeight(clamping: -5).raw, 0)
    XCTAssertEqual(DeskHeight(clamping: 6501).raw, 6500)
    XCTAssertEqual(DeskHeight(clamping: 1234).raw, 1234)
  }

  func testValidating() {
    XCTAssertNil(DeskHeight(validating: -1))
    XCTAssertNil(DeskHeight(validating: 6501))
    XCTAssertEqual(DeskHeight(validating: 0)?.raw, 0)
    XCTAssertEqual(DeskHeight(validating: 6500)?.raw, 6500)
  }

  func testSeventyThreeCmWithBase620RoundsToRaw1100() {
    XCTAssertEqual(DeskHeight(cm: 73.0, baseMM: 620)?.raw, 1100)
    XCTAssertEqual(DeskHeight.rawUnits(cm: 73.0, baseMM: 620), 1100)
  }

  func testCmConversionRoundsToNearest() {
    XCTAssertEqual(DeskHeight.rawUnits(cm: 73.1, baseMM: 620), 1110)
    XCTAssertEqual(DeskHeight.rawUnits(cm: 105.5, baseMM: 620), 4350)
    XCTAssertEqual(DeskHeight.rawUnits(cm: 62.004, baseMM: 620), 0)
    XCTAssertEqual(DeskHeight.rawUnits(cm: 62.006, baseMM: 620), 1)
  }

  func testCalibrationShiftsLabelNotRaw() {
    let height = DeskHeight(clamping: 1100)
    XCTAssertEqual(height.cm(baseMM: 620), 73.0, accuracy: 1e-9)
    XCTAssertEqual(height.cm(baseMM: 620, calibrationMM: 5), 73.5, accuracy: 1e-9)
    XCTAssertEqual(DeskHeight(cm: 73.5, baseMM: 620, calibrationMM: 5)?.raw, 1100)
  }

  func testRoundTripAtTwoDecimalCmForAllRawValues() {
    for base in [615.0, 620.0, 625.5] {
      for raw in DeskHeight.range {
        let height = DeskHeight(clamping: raw)
        let cm = height.cm(baseMM: base)
        let rounded = (cm * 100).rounded() / 100
        let back = DeskHeight(clampingCm: rounded, baseMM: base)
        XCTAssertEqual(back?.raw, raw, "base \(base) raw \(raw)")
      }
    }
  }

  func testRoundTripAtOneMillimetreResolution() {
    for raw in stride(from: 0, through: 6500, by: 10) {
      let height = DeskHeight(clamping: raw)
      let cm = height.cm(baseMM: 620)
      XCTAssertEqual(DeskHeight(cm: cm, baseMM: 620)?.raw, raw)
    }
  }

  func testCmOutOfRange() {
    XCTAssertNil(DeskHeight(cm: 61.9, baseMM: 620))
    XCTAssertNil(DeskHeight(cm: 127.1, baseMM: 620))
    XCTAssertEqual(DeskHeight(clampingCm: 61.9, baseMM: 620)?.raw, 0)
    XCTAssertEqual(DeskHeight(clampingCm: 200, baseMM: 620)?.raw, 6500)
    XCTAssertEqual(DeskHeight(cm: 127.0, baseMM: 620)?.raw, 6500)
  }

  func testNonFiniteCm() {
    XCTAssertNil(DeskHeight(cm: .nan, baseMM: 620))
    XCTAssertNil(DeskHeight(clampingCm: .infinity, baseMM: 620))
    XCTAssertEqual(DeskHeight(clampingCm: 1e300, baseMM: 620)?.raw, 6500)
    XCTAssertEqual(DeskHeight(clampingCm: -1e300, baseMM: 620)?.raw, 0)
  }

  func testComparable() {
    XCTAssertLessThan(DeskHeight(clamping: 10), DeskHeight(clamping: 20))
  }
}
