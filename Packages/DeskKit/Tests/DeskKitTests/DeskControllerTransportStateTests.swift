import DeskKitTestSupport
import XCTest

@testable import DeskKit

@MainActor
final class DeskControllerTransportStateTests: XCTestCase {
  private var directory: URL!
  private var clock: TestClock!
  private var transport: FakeTransport!
  private var controller: DeskController!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "DeskControllerTransportStateTests-\(UUID().uuidString)")
    clock = TestClock()
    transport = FakeTransport(clock: clock, connectionState: .scanning)
    controller = DeskController(
      transport: transport, positions: PositionStore(directory: directory), clock: clock,
      beginActivity: { _ in {} })
    await clock.settle()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testFailedTransportStateMapsToFailedDeskState() async {
    transport.setConnectionState(.failed("missing characteristic"))
    await clock.settle()
    XCTAssertEqual(controller.state, .failed("missing characteristic"))
  }

  func testNotFoundHintIsMirroredFromTransport() async {
    XCTAssertFalse(controller.notFoundHint)
    transport.publishNotFoundHint(true)
    await clock.settle()
    XCTAssertTrue(controller.notFoundHint)
    transport.publishNotFoundHint(false)
    await clock.settle()
    XCTAssertFalse(controller.notFoundHint)
  }

  func testInitialHintComesFromTransportSnapshot() async {
    transport.publishNotFoundHint(true)
    let late = DeskController(
      transport: transport, positions: PositionStore(directory: directory), clock: clock)
    XCTAssertTrue(late.notFoundHint)
  }
}
