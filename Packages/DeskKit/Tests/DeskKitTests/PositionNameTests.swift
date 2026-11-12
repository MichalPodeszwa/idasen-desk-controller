import XCTest

@testable import DeskKit

final class PositionNameTests: XCTestCase {
  func testTrimsWhitespaceAndNewlines() {
    XCTAssertEqual(PositionName.normalized("  Sit \n"), "Sit")
  }

  func testNormalizesToNFC() {
    let decomposed = "Cafe\u{301}"
    let composed = "Caf\u{E9}"
    XCTAssertNotEqual(Array(decomposed.unicodeScalars), Array(composed.unicodeScalars))
    XCTAssertEqual(
      Array(PositionName.normalized(decomposed).unicodeScalars),
      Array(composed.unicodeScalars))
  }

  func testKeyFoldsCase() {
    XCTAssertEqual(PositionName.key("ŁÓŻKO"), PositionName.key("łóżko"))
    XCTAssertEqual(PositionName.key("STAND"), PositionName.key("stand"))
  }

  func testKeyIsNormalizationInsensitive() {
    XCTAssertEqual(PositionName.key("É"), PositionName.key("e\u{301}"))
    XCTAssertEqual(PositionName.key("\u{C9}"), PositionName.key("\u{E9}"))
  }

  func testKeyIsLocaleIndependent() {
    XCTAssertEqual(PositionName.key("TITLE"), PositionName.key("title"))
    XCTAssertEqual(PositionName.key("I"), "i")
  }

  func testKeyFoldsSharpS() {
    XCTAssertEqual(PositionName.key("STRASSE"), PositionName.key("Straße"))
  }

  func testDistinctNamesHaveDistinctKeys() {
    XCTAssertNotEqual(PositionName.key("Sit"), PositionName.key("Stand"))
    XCTAssertNotEqual(PositionName.key("e"), PositionName.key("é"))
  }

  func testNumericNames() {
    for name in [
      "100", "100.5", " 100 ", "0", "-5", "+5", ".5", "5.", "1e3", "100,5", "1,000", "007",
      "0x10", "inf", "Infinity", "NaN",
    ] {
      XCTAssertTrue(PositionName.isNumeric(name), name)
    }
  }

  func testNonNumericNames() {
    for name in ["Sit", "Stand 2", "2nd", "100 cm", "1,000,000", "1,2,3", "a1", "-", ",", "…"] {
      XCTAssertFalse(PositionName.isNumeric(name), name)
    }
  }

  func testValidatedReturnsNormalized() throws {
    XCTAssertEqual(try PositionName.validated("  Sit\n"), "Sit")
  }

  func testValidatedRejectsEmpty() {
    for name in ["", "   ", "\n\t "] {
      XCTAssertThrowsError(try PositionName.validated(name)) {
        XCTAssertEqual($0 as? PositionName.Rejection, .empty)
      }
    }
  }

  func testValidatedRejectsNumeric() {
    for name in ["100", "100.5", " 73 "] {
      XCTAssertThrowsError(try PositionName.validated(name)) {
        XCTAssertEqual($0 as? PositionName.Rejection, .numeric)
      }
    }
  }
}

extension PositionNameTests {
  func testSlugFixtures() {
    let fixtures = [
      ("Żółte biurko", "zolte-biurko"),
      ("Biurko nieżółte", "biurko-niezolte"),
      ("Standing", "standing"),
      ("Żółć & Gęś", "zolc-ges"),
      ("Straße", "strasse"),
      ("🙂", ""),
    ]
    for (name, slug) in fixtures {
      XCTAssertEqual(PositionName.slug(name), slug, name)
    }
  }

  func testSlugEdgeCases() {
    let fixtures = [
      ("Cafe\u{301}", "cafe"),
      ("Caf\u{E9}", "cafe"),
      ("L\u{0301}ad", "lad"),
      ("STANDING", "standing"),
      ("  --Sit--down--  ", "sit-down"),
      ("***", ""),
      ("", ""),
      ("Desk 2", "desk-2"),
      ("2nd", "2nd"),
      ("a__b..c", "a-b-c"),
      ("Привет мир", "privet-mir"),
      ("１２３", "123"),
    ]
    for (name, slug) in fixtures {
      XCTAssertEqual(PositionName.slug(name), slug, name)
    }
  }

  func testSlugIsStableForEquivalentInput() {
    XCTAssertEqual(PositionName.slug("Éa"), PositionName.slug("E\u{301}a"))
  }

  func testValidatedRejectsNumericSlug() {
    for name in ["１２３", "４２"] {
      XCTAssertThrowsError(try PositionName.validated(name), name) {
        XCTAssertEqual($0 as? PositionName.Rejection, .numericSlug)
      }
    }
  }

  func testValidatedAllowsEmptySlug() throws {
    XCTAssertEqual(try PositionName.validated("🙂"), "🙂")
  }
}
