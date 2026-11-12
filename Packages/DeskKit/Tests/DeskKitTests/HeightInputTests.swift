import XCTest

@testable import DeskKit

final class HeightInputTests: XCTestCase {
  func testParsesPlainAndCommaDecimals() {
    XCTAssertEqual(HeightInput.parse("100"), 100)
    XCTAssertEqual(HeightInput.parse(" 100.5 "), 100.5)
    XCTAssertEqual(HeightInput.parse("100,5"), 100.5)
  }

  func testRejectsGarbageAndNonFinite() {
    XCTAssertNil(HeightInput.parse(""))
    XCTAssertNil(HeightInput.parse("abc"))
    XCTAssertNil(HeightInput.parse("1,000,5"))
    XCTAssertNil(HeightInput.parse("inf"))
    XCTAssertNil(HeightInput.parse("nan"))
  }
}
