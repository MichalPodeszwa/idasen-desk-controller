import XCTest

@testable import DeskKit

final class MoveKindDirectionTests: XCTestCase {
  private let id = MoveID(rawValue: 1)

  func testTargetDirectionFollowsCurrentHeight() {
    XCTAssertEqual(MoveKind.toTarget(raw: 1000, id: id).direction(currentRaw: 3000), .down)
    XCTAssertEqual(MoveKind.toTarget(raw: 4000, id: id).direction(currentRaw: 3000), .up)
    XCTAssertEqual(MoveKind.toTarget(raw: 4000, id: id).direction(currentRaw: nil), .up)
  }

  func testRelativeDirectionFollowsSign() {
    XCTAssertEqual(MoveKind.relative(deltaRaw: -200, id: id).direction(currentRaw: nil), .down)
    XCTAssertEqual(MoveKind.relative(deltaRaw: 200, id: id).direction(currentRaw: nil), .up)
  }

  func testHoldAndExternalKeepTheirDirection() {
    XCTAssertEqual(MoveKind.hold(.down, id: id).direction(currentRaw: 0), .down)
    XCTAssertEqual(MoveKind.external(.up).direction(currentRaw: 6500), .up)
  }
}
