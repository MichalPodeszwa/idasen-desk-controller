import XCTest

@testable import DeskKit

final class DeskKitTests: XCTestCase {
  func testModuleLoads() {
    XCTAssertEqual(String(describing: DeskKit.self), "DeskKit")
  }
}
