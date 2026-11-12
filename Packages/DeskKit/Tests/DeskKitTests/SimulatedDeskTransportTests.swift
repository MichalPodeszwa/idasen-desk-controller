import DeskKitTestSupport
import XCTest

@testable import DeskKit

@MainActor
final class SimulatedDeskTransportTests: XCTestCase {
  private var clock: TestClock!
  private var desk: SimulatedDeskTransport!
  private var received: [DeskTransportEvent] = []
  private var collector: Task<Void, Never>?

  override func setUp() async throws {
    clock = TestClock()
    desk = makeDesk()
  }

  override func tearDown() async throws {
    collector?.cancel()
  }

  private func makeDesk(
    _ configure: (inout SimulatedDeskTransport.Configuration) -> Void = { _ in }
  ) -> SimulatedDeskTransport {
    var configuration = SimulatedDeskTransport.Configuration()
    configure(&configuration)
    let desk = SimulatedDeskTransport(clock: clock, configuration: configuration)
    let events = desk.events
    collector?.cancel()
    received = []
    collector = Task { [weak self] in
      for await event in events { self?.received.append(event) }
    }
    return desk
  }

  private func connected() async {
    desk.connect()
    await clock.settle()
  }

  private func startReferenceMove(to raw: Int) async throws {
    try await desk.write(DeskCommand.wake.bytes, to: .control, type: .withResponse)
    try await desk.write(DeskCommand.stop.bytes, to: .control, type: .withResponse)
    try await desk.write(
      ReferenceInput.target(DeskHeight(clamping: raw)), to: .referenceInput, type: .withoutResponse)
  }

  private var samples: [HeightSample] {
    received.compactMap {
      if case .sample(let sample) = $0 { sample } else { nil }
    }
  }

  private var states: [TransportConnectionState] {
    received.compactMap {
      if case .connectionState(let state) = $0 { state } else { nil }
    }
  }

  func testConnectSequenceReportsStateBaseOffsetAndInitialSample() async {
    await connected()
    XCTAssertEqual(states, [.scanning, .connecting, .connected])
    XCTAssertEqual(desk.baseOffsetMM, 620)
    XCTAssertTrue(received.contains(.baseOffset(620)))
    XCTAssertEqual(samples, [HeightSample(heightRaw: 1000, speedRaw: 0)])
    XCTAssertEqual(desk.discoveredDesks.map(\.name), ["Desk 1234"])
  }

  func testConnectHonoursDelays() async {
    desk = makeDesk { $0.connectDelay = .milliseconds(300) }
    desk.connect()
    await clock.advance(by: .milliseconds(200))
    XCTAssertEqual(desk.connectionState, .scanning)
    await clock.advance(by: .milliseconds(200))
    XCTAssertEqual(desk.connectionState, .connecting)
    await clock.advance(by: .milliseconds(300))
    XCTAssertEqual(desk.connectionState, .connected)
  }

  func testBaseOffsetFollowsConfigurationAndMayBeUnanswered() async {
    desk = makeDesk { $0.baseMM = 615 }
    await connected()
    XCTAssertEqual(desk.baseOffsetMM, 615)

    desk = makeDesk { $0.respondsToBaseOffset = false }
    await connected()
    XCTAssertNil(desk.baseOffsetMM)
    XCTAssertTrue(received.contains(.baseOffset(nil)))
  }

  func testUserIDIsOptionalAndWritable() {
    XCTAssertNil(desk.dpgResponse(to: DPG.readFrame(.userID)))
    let id = Data([0x00, 0x11, 0x22])
    desk = makeDesk { $0.userID = id }
    XCTAssertEqual(
      desk.dpgResponse(to: DPG.readFrame(.userID)), Data([0x01, 0x86, 0x00]) + id)
    let patch = DPG.userIDPatchFrame(response: Data([0x01, 0x86, 0x00]) + id)
    XCTAssertNotNil(patch)
    _ = desk.dpgResponse(to: patch!)
    XCTAssertEqual(desk.userID, Data([0x01, 0x11, 0x22]))
  }

  func testNoNotificationsAtRest() async {
    await connected()
    received = []
    await clock.advance(by: .seconds(5))
    XCTAssertTrue(received.isEmpty)
  }

  func testNotifiesAboutEveryHundredMillisecondsOnlyWhileMoving() async throws {
    await connected()
    received = []
    try await startReferenceMove(to: 1400)
    await clock.advance(by: .milliseconds(450))
    XCTAssertEqual(samples.count, 4)
    XCTAssertTrue(samples.allSatisfy { $0.speedRaw > 0 })
    XCTAssertEqual(samples.map(\.heightRaw), samples.map(\.heightRaw).sorted())
    try await desk.write(
      ReferenceInput.target(DeskHeight(clamping: 1400)), to: .referenceInput, type: .withoutResponse
    )

    await clock.advance(by: .seconds(3))
    let last = try XCTUnwrap(samples.last)
    XCTAssertEqual(last.speedRaw, 0)
    XCTAssertEqual(desk.heightRaw, 1400)
    XCTAssertEqual(last.heightRaw, 1400 + desk.configuration.finalNotificationOffsetRaw)
    XCTAssertEqual(samples.filter(\.isStationary).count, 1)

    let count = samples.count
    await clock.advance(by: .seconds(5))
    XCTAssertEqual(samples.count, count)
  }

  func testActiveReadReturnsTrueValueNotNotifiedOne() async throws {
    await connected()
    try await startReferenceMove(to: 1400)
    for _ in 0..<40 {
      try await desk.write(
        ReferenceInput.target(DeskHeight(clamping: 1400)), to: .referenceInput,
        type: .withoutResponse)
      await clock.advance(by: .milliseconds(100))
    }
    let read = try await desk.readHeight()
    XCTAssertEqual(read, HeightSample(heightRaw: 1400, speedRaw: 0))
    XCTAssertNotEqual(samples.last?.heightRaw, read.heightRaw)
  }

  func testSpeedAndRamp() async throws {
    await connected()
    try await startReferenceMove(to: 5000)
    let early = try await desk.readHeight()
    XCTAssertEqual(early.speedRaw, 0)
    await clock.advance(by: .milliseconds(100))
    let ramping = try await desk.readHeight()
    XCTAssertGreaterThan(ramping.speedRaw, 0)
    XCTAssertLessThan(ramping.speedRaw, 380)
    for _ in 0..<5 {
      try await desk.write(
        ReferenceInput.target(DeskHeight(clamping: 5000)), to: .referenceInput,
        type: .withoutResponse)
      await clock.advance(by: .milliseconds(100))
    }
    let cruising = try await desk.readHeight()
    XCTAssertEqual(cruising.speedRaw, 380)
  }

  func testReferenceInputIgnoredUntilWake() async throws {
    await connected()
    try await desk.write(
      ReferenceInput.target(DeskHeight(clamping: 3000)), to: .referenceInput, type: .withoutResponse
    )
    await clock.advance(by: .seconds(1))
    XCTAssertEqual(desk.heightRaw, 1000)
  }

  func testPulseRunsAboutOneSecondPerWrite() async throws {
    await connected()
    try await desk.write(DeskCommand.up.bytes, to: .control, type: .withResponse)
    await clock.advance(by: .milliseconds(900))
    XCTAssertTrue(desk.isMoving)
    await clock.advance(by: .milliseconds(1100))
    XCTAssertFalse(desk.isMoving)
    let travelled = desk.heightRaw - 1000
    XCTAssertGreaterThan(travelled, 250)
    XCTAssertLessThan(travelled, 500)
  }

  func testPulsesKeptAliveKeepMovingDownToLimit() async throws {
    desk = makeDesk { $0.initialRaw = 300 }
    await connected()
    for _ in 0..<20 {
      try await desk.write(DeskCommand.down.bytes, to: .control, type: .withResponse)
      await clock.advance(by: .milliseconds(300))
    }
    XCTAssertEqual(desk.heightRaw, 0)
    XCTAssertFalse(desk.isMoving)
  }

  func testDirectionSentinelMovesTowardLimitWhileRefreshedThenCoasts() async throws {
    await connected()
    try await desk.write(DeskCommand.wake.bytes, to: .control, type: .withResponse)
    for _ in 0..<10 {
      try await desk.write(ReferenceInput.directionUp, to: .referenceInput, type: .withoutResponse)
      await clock.advance(by: .milliseconds(100))
    }
    XCTAssertTrue(desk.isMoving)
    await clock.advance(by: .seconds(2))
    XCTAssertFalse(desk.isMoving)
    XCTAssertLessThan(desk.heightRaw, 6500)
  }

  func testStopCommandsStopQuickly() async throws {
    for stop in [
      (DeskCharacteristic.control, DeskCommand.stop.bytes), (.referenceInput, ReferenceInput.stop),
    ] {
      desk = makeDesk()
      await connected()
      try await startReferenceMove(to: 6000)
      await clock.advance(by: .seconds(1))
      try await desk.write(stop.1, to: stop.0, type: .withResponse)
      await clock.advance(by: .milliseconds(300))
      XCTAssertFalse(desk.isMoving)
      let resting = desk.heightRaw
      await clock.advance(by: .seconds(3))
      XCTAssertEqual(desk.heightRaw, resting)
    }
  }

  func testReachesLimitsWithoutOvershoot() async throws {
    desk = makeDesk { $0.initialRaw = 6300 }
    await connected()
    try await startReferenceMove(to: 6500)
    for _ in 0..<20 {
      try await desk.write(
        ReferenceInput.target(DeskHeight(clamping: 6500)), to: .referenceInput,
        type: .withoutResponse)
      await clock.advance(by: .milliseconds(100))
    }
    XCTAssertEqual(desk.heightRaw, 6500)
  }

  func testPairingRequiredFault() async {
    desk = makeDesk { _ in }
    desk.faults.pairingRequired = .pairingModeNeeded
    await connected()
    XCTAssertEqual(desk.connectionState, .pairingRequired(.pairingModeNeeded))
    XCTAssertEqual(states.last, .pairingRequired(.pairingModeNeeded))
    do {
      _ = try await desk.readHeight()
      XCTFail("expected notConnected")
    } catch {
      XCTAssertEqual(error as? DeskTransportError, .notConnected)
    }

    desk.faults.pairingRequired = nil
    await connected()
    XCTAssertEqual(desk.connectionState, .connected)
  }

  func testNotFoundFaultSearchesAndHintsAfterDelay() async {
    desk.faults.notFound = true
    await connected()
    XCTAssertEqual(desk.connectionState, .scanning)
    XCTAssertFalse(desk.notFoundHint)
    await clock.advance(by: .seconds(16))
    XCTAssertTrue(desk.notFoundHint)
    XCTAssertTrue(received.contains(.notFoundHint(true)))

    desk.faults.notFound = false
    await connected()
    XCTAssertEqual(desk.connectionState, .connected)
    XCTAssertFalse(desk.notFoundHint)
    XCTAssertTrue(received.contains(.notFoundHint(false)))
  }

  func testLinkLossDisconnectsAndFailsReadsAndWrites() async throws {
    await connected()
    desk.simulateLinkLoss()
    await clock.settle()
    XCTAssertEqual(states.last, .disconnected)
    do {
      try await desk.write(DeskCommand.stop.bytes, to: .control, type: .withResponse)
      XCTFail("expected notConnected")
    } catch {
      XCTAssertEqual(error as? DeskTransportError, .notConnected)
    }
    await connected()
    XCTAssertEqual(desk.connectionState, .connected)
  }

  func testSlowNotificationsFault() async throws {
    await connected()
    desk.faults.notificationInterval = .milliseconds(500)
    received = []
    try await startReferenceMove(to: 3000)
    await clock.advance(by: .milliseconds(1200))
    XCTAssertEqual(samples.count, 2)
  }

  func testForgetClearsKnownDeskUntilPicked() async {
    await connected()
    desk.forget()
    XCTAssertEqual(desk.connectionState, .disconnected)
    XCTAssertTrue(desk.discoveredDesks.isEmpty)
    await connected()
    XCTAssertEqual(desk.connectionState, .scanning)
    XCTAssertEqual(desk.discoveredDesks.count, 1)
    desk.connect(to: desk.desk.id)
    await clock.settle()
    XCTAssertEqual(desk.connectionState, .connected)
  }
}
