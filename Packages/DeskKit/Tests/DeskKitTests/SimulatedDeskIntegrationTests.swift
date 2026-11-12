import DeskKitTestSupport
import XCTest

@testable import DeskKit

@MainActor
private final class TestHoldInput: HoldInputSource {
  var isHeld = true
}

@MainActor
final class SimulatedDeskIntegrationTests: XCTestCase {
  private var directory: URL!
  private var clock: TestClock!
  private var desk: SimulatedDeskTransport!
  private var controller: DeskController!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "SimulatedDeskIntegrationTests-\(UUID().uuidString)")
    clock = TestClock()
    desk = SimulatedDeskTransport(clock: clock)
    controller = DeskController(
      transport: desk, positions: PositionStore(directory: directory), clock: clock,
      beginActivity: { _ in {} })
    controller.connect()
    await clock.settle()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func run(for duration: Duration) async {
    await clock.advance(by: duration)
  }

  private func refresh(toward raw: Int, for duration: Duration) async throws {
    let target = ReferenceInput.target(DeskHeight(clamping: raw))
    for _ in 0..<(Int(duration / .milliseconds(100))) {
      try await desk.write(target, to: .referenceInput, type: .withoutResponse)
      await run(for: .milliseconds(100))
    }
  }

  func testConnectsAndReportsInitialHeight() {
    XCTAssertEqual(controller.state, .connected(.idle))
    XCTAssertEqual(controller.heightRaw, 1000)
    XCTAssertEqual(controller.baseOffsetMM, 620)
  }

  func testMoveToTargetArrivesWithinFiveMillimetres() async throws {
    let ticket = try controller.startMove(toRaw: 3000)
    await run(for: .seconds(12))
    let result = await ticket.result()
    let settled = try result.get()
    XCTAssertLessThanOrEqual(abs(settled - 3000), 50)
    XCTAssertLessThanOrEqual(abs(desk.heightRaw - 3000), 50)
    XCTAssertFalse(desk.isMoving)
    XCTAssertEqual(controller.state, .connected(.idle))
  }

  func testMoveDownArrives() async throws {
    desk.setHeight(raw: 4000)
    let ticket = try controller.startMove(toRaw: 2500)
    await run(for: .seconds(12))
    let settled = try await ticket.value()
    XCTAssertLessThanOrEqual(abs(settled - 2500), 50)
  }

  func testCollisionFailsMoveAndNothingMovesAfterwards() async throws {
    desk.injectCollision(atRaw: 2000)
    let ticket = try controller.startMove(toRaw: 3000)
    await run(for: .seconds(8))
    let result = await ticket.result()
    XCTAssertEqual(result, .failure(.moveFailed(.stalled)))
    XCTAssertEqual(desk.heightRaw, 2000)

    await run(for: .seconds(5))
    XCTAssertEqual(desk.heightRaw, 2000)
    XCTAssertFalse(desk.isMoving)
    XCTAssertEqual(controller.state, .connected(.idle))
  }

  func testCollidedDeskIgnoresCommandsUntilStopReceived() async throws {
    desk.injectCollision(atRaw: 1500)
    try await desk.write(DeskCommand.wake.bytes, to: .control, type: .withResponse)
    try await refresh(toward: 3000, for: .seconds(3))
    XCTAssertEqual(desk.heightRaw, 1500)
    XCTAssertTrue(desk.isBlockedByCollision)

    try await desk.write(DeskCommand.up.bytes, to: .control, type: .withResponse)
    try await refresh(toward: 3000, for: .seconds(2))
    XCTAssertEqual(desk.heightRaw, 1500)

    try await desk.write(DeskCommand.stop.bytes, to: .control, type: .withResponse)
    XCTAssertFalse(desk.isBlockedByCollision)
    try await desk.write(DeskCommand.down.bytes, to: .control, type: .withResponse)
    await run(for: .seconds(1))
    XCTAssertLessThan(desk.heightRaw, 1500)
  }

  func testRetryAfterCollisionDrivesIntoObstacleAgain() async throws {
    desk.injectCollision(atRaw: 2000)
    let first = try controller.startMove(toRaw: 3000)
    await run(for: .seconds(8))
    _ = await first.result()
    let second = try controller.startMove(toRaw: 3000)
    await run(for: .seconds(6))
    let result = await second.result()
    XCTAssertEqual(result, .failure(.moveFailed(.didNotStart)))
    XCTAssertEqual(desk.heightRaw, 2000)
  }

  func testPanelTakeoverInterruptsMove() async throws {
    let ticket = try controller.startMove(toRaw: 4000)
    await run(for: .seconds(2))
    desk.pressPanel(.down, for: .seconds(2))
    await run(for: .seconds(1))
    let result = await ticket.result()
    XCTAssertEqual(result, .failure(.interrupted))
    await run(for: .seconds(4))
    XCTAssertFalse(desk.isMoving)
    XCTAssertEqual(controller.state, .connected(.idle))
  }

  func testPanelMovementWhileIdleShowsExternalActivity() async throws {
    desk.pressPanel(.up, for: .seconds(2))
    await run(for: .milliseconds(500))
    XCTAssertEqual(controller.state, .connected(.moving(.external(.up))))
    await run(for: .seconds(4))
    XCTAssertEqual(controller.state, .connected(.idle))
    XCTAssertGreaterThan(controller.heightRaw ?? 0, 1500)
  }

  func testDeskThatDoesNotStartFailsMove() async throws {
    desk.faults.doesNotStart = true
    let ticket = try controller.startMove(toRaw: 3000)
    await run(for: .seconds(4))
    let result = await ticket.result()
    XCTAssertEqual(result, .failure(.moveFailed(.didNotStart)))
    XCTAssertEqual(desk.heightRaw, 1000)
  }

  func testHoldWithMissedReleaseStopsViaDeadManCheck() async throws {
    let input = TestHoldInput()
    let ticket = try controller.beginHold(.up, input: input)
    await run(for: .seconds(2))
    XCTAssertTrue(desk.isMoving)
    let heightAtRelease = desk.heightRaw

    input.isHeld = false
    await run(for: .seconds(2))
    let result = await ticket.result()
    XCTAssertNotNil(try? result.get())
    XCTAssertFalse(desk.isMoving)
    XCTAssertLessThan(desk.heightRaw - heightAtRelease, 300)

    let resting = desk.heightRaw
    await run(for: .seconds(3))
    XCTAssertEqual(desk.heightRaw, resting)
  }

  func testHoldVariantsMoveAndStop() async throws {
    for variant in [HoldVariant.targetLimit, .commandPulses, .directionSentinel] {
      desk.setHeight(raw: 2000)
      let input = TestHoldInput()
      let ticket = try controller.beginHold(.up, input: input, variant: variant)
      await run(for: .seconds(2))
      XCTAssertGreaterThan(desk.heightRaw, 2400, "\(variant)")
      input.isHeld = false
      await run(for: .seconds(2))
      _ = await ticket.result()
      XCTAssertFalse(desk.isMoving, "\(variant)")
    }
  }

  func testSimulatorWatchdogStopsWithinCoastTimeWhenRefreshesStop() async throws {
    try await desk.write(DeskCommand.wake.bytes, to: .control, type: .withResponse)
    try await desk.write(DeskCommand.stop.bytes, to: .control, type: .withResponse)
    try await refresh(toward: 6000, for: .seconds(1))
    XCTAssertTrue(desk.isMoving)
    let atLastRefresh = desk.heightRaw

    await run(for: .seconds(1))
    await run(for: .milliseconds(400))
    XCTAssertFalse(desk.isMoving)
    let coasted = desk.heightRaw - atLastRefresh
    XCTAssertGreaterThan(coasted, 0)
    XCTAssertLessThan(coasted, 480)

    let resting = desk.heightRaw
    await run(for: .seconds(5))
    XCTAssertEqual(desk.heightRaw, resting)
  }

  func testLinkLossFailsMoveAndDeskStopsWithinCoastTime() async throws {
    let ticket = try controller.startMove(toRaw: 5000)
    await run(for: .seconds(1))
    XCTAssertTrue(desk.isMoving)
    let heightAtLoss = desk.heightRaw
    desk.simulateLinkLoss()
    await run(for: desk.configuration.coastTimeout + .milliseconds(300))

    let result = await ticket.result()
    XCTAssertEqual(result, .failure(.notConnected))
    XCTAssertEqual(controller.state, .disconnected)
    XCTAssertNil(controller.heightRaw)
    XCTAssertFalse(desk.isMoving)
    let coasted = desk.heightRaw - heightAtLoss
    XCTAssertGreaterThan(coasted, 0)
    XCTAssertLessThan(coasted, 500)

    let resting = desk.heightRaw
    await run(for: .seconds(3))
    XCTAssertEqual(desk.heightRaw, resting)
  }

  func testPanelIgnoresStopFromTheApp() async throws {
    desk.pressPanel(.up, for: .seconds(2))
    await run(for: .milliseconds(500))
    await controller.stop()
    XCTAssertTrue(desk.isMoving)
    await run(for: .seconds(3))
    XCTAssertFalse(desk.isMoving)
  }

  func testNonZeroFinalNotificationEndsExternalActivityViaIdleTimeout() async throws {
    desk = SimulatedDeskTransport(
      clock: clock,
      configuration: {
        var configuration = SimulatedDeskTransport.Configuration()
        configuration.finalNotificationSpeedRaw = 40
        return configuration
      }())
    controller = DeskController(
      transport: desk, positions: PositionStore(directory: directory), clock: clock,
      beginActivity: { _ in {} })
    controller.connect()
    await clock.settle()

    desk.pressPanel(.up, for: .seconds(1))
    await run(for: .seconds(2))
    XCTAssertEqual(controller.state, .connected(.moving(.external(.up))))
    await run(for: .milliseconds(1200))
    XCTAssertEqual(controller.state, .connected(.idle))
  }
}
