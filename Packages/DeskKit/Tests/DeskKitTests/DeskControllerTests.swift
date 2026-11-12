import DeskKitTestSupport
import XCTest

@testable import DeskKit

@MainActor
private final class TestHoldInput: HoldInputSource {
  var isHeld = true
}

@MainActor
final class DeskControllerTests: XCTestCase {
  private var directory: URL!
  private var clock: TestClock!
  private var transport: FakeTransport!
  private var controller: DeskController!
  private var activityLog: [String] = []

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "DeskControllerTests-\(UUID().uuidString)")
    clock = TestClock()
    transport = FakeTransport(clock: clock, restingSample: sample(1000))
    activityLog = []
    controller = makeController()
    await clock.settle()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeController() -> DeskController {
    DeskController(
      transport: transport, positions: PositionStore(directory: directory), clock: clock,
      beginActivity: { [unowned self] reason in
        self.activityLog.append("begin \(reason)")
        return { self.activityLog.append("end") }
      })
  }

  private func sample(_ height: Int, _ speed: Int = 0) -> HeightSample {
    HeightSample(heightRaw: height, speedRaw: speed)
  }

  private func ms(_ value: Int) -> Duration {
    .milliseconds(value)
  }

  private func finished(_ ticket: MoveTicket) async -> Result<Int, DeskControllerError>? {
    guard ticket.isFinished else { return nil }
    return await ticket.result()
  }

  private func assertFinished(
    _ ticket: MoveTicket, _ expected: Result<Int, DeskControllerError>,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    let result = await finished(ticket)
    XCTAssertEqual(result, expected, file: file, line: line)
  }

  private func repeated(_ label: String, _ count: Int) -> [String] {
    Array(repeating: label, count: count)
  }

  private var log: [String] {
    transport.writes.map(label)
  }

  private func label(_ write: FakeTransport.Write) -> String {
    let data = write.data
    switch write.characteristic {
    case .control:
      switch data {
      case DeskCommand.wake.bytes: return "wake"
      case DeskCommand.stop.bytes: return "stop"
      case DeskCommand.up.bytes: return "up"
      case DeskCommand.down.bytes: return "down"
      default: return "control?"
      }
    case .referenceInput:
      switch data {
      case ReferenceInput.stop: return "refStop"
      case ReferenceInput.directionUp: return "dirUp"
      case ReferenceInput.directionDown: return "dirDown"
      default:
        let bytes = Array(data)
        return "T\(Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)))"
      }
    case .dpg:
      return "dpg"
    }
  }

  private func assertWriteTypes(file: StaticString = #filePath, line: UInt = #line) {
    for write in transport.writes {
      let expected: DeskWriteType =
        ["wake", "stop", "refStop"].contains(label(write)) ? .withResponse : .withoutResponse
      XCTAssertEqual(write.type, expected, label(write), file: file, line: line)
    }
  }

  private func startStop() -> Task<Void, Never> {
    Task { await controller.stop() }
  }

  // MARK: Move to height

  func testArrivalReturnsSettleReadWithoutStop() async throws {
    transport.readScript = [
      sample(1000), sample(1100, 40), sample(1300, 40), sample(1480, 10), sample(1500),
      sample(1500), sample(1502),
    ]
    let ticket = try controller.startMove(toRaw: 1500)
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 1500, id: ticket.id))))
    XCTAssertEqual(controller.currentMoveID, ticket.id)

    await clock.advance(by: ms(400))
    XCTAssertFalse(ticket.isFinished)
    await clock.advance(by: ms(500))

    let result = await finished(ticket)
    XCTAssertEqual(result, .success(1502))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T1500", 5))
    assertWriteTypes()
    XCTAssertEqual(transport.readTimes, [0, 0, 100, 200, 300, 400, 900].map(ms))
    XCTAssertEqual(controller.state, .connected(.idle))
    XCTAssertNil(controller.currentMoveID)
    XCTAssertEqual(controller.heightRaw, 1502)
    XCTAssertEqual(activityLog, ["begin Moving the desk", "end"])
  }

  func testArrivalWithoutAnyNotificationAndNoReadsWhileIdle() async throws {
    await clock.advance(by: .seconds(5))
    XCTAssertTrue(transport.readTimes.isEmpty)

    transport.readScript = [
      sample(3000), sample(2900, -40), sample(2700, -40), sample(2510, -5), sample(2505),
      sample(2505), sample(2500),
    ]
    let result = try await runToCompletion(controller.startMove(toRaw: 2500))
    XCTAssertEqual(result, .success(2500))
    let readsAfterMove = transport.readTimes.count
    let writesAfterMove = transport.writes.count

    await clock.advance(by: .seconds(10))
    XCTAssertEqual(transport.readTimes.count, readsAfterMove)
    XCTAssertEqual(transport.writes.count, writesAfterMove)
    XCTAssertFalse(log.contains("refStop"))
  }

  func testSingleZeroSpeedNotificationDoesNotEndMove() async throws {
    transport.readScript = [
      sample(1000), sample(1100, 40), sample(1300, 40), sample(1500, 40), sample(1700, 40),
      sample(2000), sample(2000), sample(2001),
    ]
    let ticket = try controller.startMove(toRaw: 2000)
    await clock.advance(by: ms(150))
    transport.push(sample(1250, 0))
    await clock.settle()
    XCTAssertEqual(controller.heightRaw, 1250)
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 2000, id: ticket.id))))
    XCTAssertFalse(ticket.isFinished)

    await clock.advance(by: ms(2000))
    let result = await finished(ticket)
    XCTAssertEqual(result, .success(2001))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T2000", 6))
  }

  func testNeverStartsFailsAfterGraceAndStops() async throws {
    transport.readScript = [sample(1000)]
    let ticket = try controller.startMove(toRaw: 2000)
    await clock.settle()
    await clock.advance(by: ms(1400))
    XCTAssertFalse(ticket.isFinished)
    XCTAssertFalse(log.contains("refStop"))

    await clock.advance(by: ms(100))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T2000", 16) + ["stop", "refStop"])
    XCTAssertFalse(ticket.isFinished)
    await clock.advance(by: ms(300))

    let result = await finished(ticket)
    XCTAssertEqual(result, .failure(.moveFailed(.didNotStart)))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T2000", 16) + ["stop", "refStop"])
    assertWriteTypes()
    XCTAssertEqual(controller.state, .connected(.idle))
  }

  func testStallAfterMovementFailsWithoutRetry() async throws {
    transport.readScript = [
      sample(1000), sample(1100, 40), sample(1200, 40), sample(1250), sample(1250),
    ]
    let ticket = try controller.startMove(toRaw: 2000)
    await clock.advance(by: ms(600))

    let result = await finished(ticket)
    XCTAssertEqual(result, .failure(.moveFailed(.stalled)))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T2000", 4) + ["stop", "refStop"])
    assertWriteTypes()

    await clock.advance(by: .seconds(5))
    XCTAssertEqual(log.filter { $0 == "wake" }.count, 1)
    XCTAssertEqual(log.count, 8)
  }

  func testStationaryStartIsGraceNotStall() async throws {
    transport.readScript = [
      sample(1000), sample(1000), sample(1000), sample(1000), sample(1200, 40), sample(1600, 40),
      sample(2000), sample(2000), sample(2000),
    ]
    let ticket = try controller.startMove(toRaw: 2000)
    await clock.advance(by: ms(1500))
    let result = await finished(ticket)
    XCTAssertEqual(result, .success(2000))
    XCTAssertFalse(log.contains("refStop"))
  }

  func testOppositeSpeedIsTakeover() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1050, -30), sample(1040)]
    let ticket = try controller.startMove(toRaw: 2000)
    await clock.advance(by: ms(100))
    XCTAssertEqual(log, ["wake", "stop", "T2000", "T2000", "stop", "refStop"])
    await clock.advance(by: ms(300))

    let result = await finished(ticket)
    XCTAssertEqual(result, .failure(.interrupted))
    XCTAssertEqual(log, ["wake", "stop", "T2000", "T2000", "stop", "refStop"])
  }

  func testTimeoutAfterThirtySeconds() async throws {
    transport.readScript =
      [sample(0)] + (1...300).map { sample($0 * 5, 10) } + [sample(1505)]
    let ticket = try controller.startMove(toRaw: 6000)
    await clock.settle()
    await clock.advance(by: .seconds(29) + ms(900))
    XCTAssertFalse(ticket.isFinished)
    await clock.advance(by: ms(100))
    await clock.advance(by: ms(300))

    let result = await finished(ticket)
    XCTAssertEqual(result, .failure(.moveFailed(.timedOut)))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T6000", 300) + ["stop", "refStop"])
    XCTAssertEqual(transport.writes.last?.at, .seconds(30))
  }

  func testSkipsRequestsBelowTwoMillimetres() async throws {
    transport.readScript = [sample(1000)]
    let near = try controller.startMove(toRaw: 1019)
    await clock.settle()
    await assertFinished(near, .success(1000))
    let below = try controller.startMove(toRaw: 981)
    await clock.settle()
    await assertFinished(below, .success(1000))
    XCTAssertTrue(transport.writes.isEmpty)
    XCTAssertEqual(controller.state, .connected(.idle))

    _ = try controller.startMove(toRaw: 1020)
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop", "T1020"])
  }

  func testRejectsOutOfRangeAndDisconnected() async throws {
    XCTAssertThrowsError(try controller.startMove(toRaw: 6501)) {
      XCTAssertEqual($0 as? DeskControllerError, .outOfRange)
    }
    XCTAssertThrowsError(try controller.startMove(toRaw: -1)) {
      XCTAssertEqual($0 as? DeskControllerError, .outOfRange)
    }

    transport = FakeTransport(clock: clock, connectionState: .disconnected)
    controller = makeController()
    XCTAssertEqual(controller.state, .disconnected)
    XCTAssertThrowsError(try controller.startMove(toRaw: 1000)) {
      XCTAssertEqual($0 as? DeskControllerError, .notConnected)
    }
    XCTAssertThrowsError(try controller.beginHold(.up, input: TestHoldInput())) {
      XCTAssertEqual($0 as? DeskControllerError, .notConnected)
    }
    await controller.stop()
    XCTAssertTrue(transport.writes.isEmpty)
    XCTAssertTrue(transport.failedWrites.isEmpty)
  }

  func testSkippedTickWhenWriteWithoutResponseIsUnavailable() async throws {
    transport.readScript = [sample(1000)]
    _ = try controller.startMove(toRaw: 2000)
    await clock.settle()
    transport.canSendWriteWithoutResponse = false
    await clock.advance(by: ms(300))
    XCTAssertEqual(log, ["wake", "stop", "T2000"])
    XCTAssertEqual(transport.readTimes.count, 5)

    transport.canSendWriteWithoutResponse = true
    await clock.advance(by: ms(100))
    XCTAssertEqual(log, ["wake", "stop", "T2000", "T2000"])
  }

  // MARK: Stop and interruption

  func testStopDuringMoveSendsStopAfterLastTargetAndResendsWhileMoving() async throws {
    transport.readScript = [
      sample(1000), sample(1100, 40), sample(1200, 40), sample(1300, 40), sample(1350, 20),
    ]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(250))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T3000", 3))

    _ = startStop()
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T3000", 3) + ["stop", "refStop"])
    XCTAssertEqual(controller.state, .connected(.idle))
    XCTAssertFalse(ticket.isFinished)

    await clock.advance(by: ms(300))
    let result = await finished(ticket)
    XCTAssertEqual(result, .failure(.interrupted))
    XCTAssertEqual(
      log, ["wake", "stop"] + repeated("T3000", 3) + ["stop", "refStop", "stop", "refStop"])
    assertWriteTypes()
    XCTAssertEqual(transport.writes.suffix(4).map(\.at), [250, 250, 550, 550].map(ms))

    await clock.advance(by: .seconds(5))
    XCTAssertEqual(transport.writes.count, 9)
    XCTAssertEqual(activityLog, ["begin Moving the desk", "end"])
  }

  func testStopIsNotResentWhenDeskHasStopped() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1120)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(50))
    _ = startStop()
    await clock.advance(by: ms(300))
    await assertFinished(ticket, .failure(.interrupted))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "stop", "refStop"])
  }

  func testStopWaitsForInFlightTargetWrite() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1150)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.settle()
    transport.holdsWrites = true
    await clock.advance(by: ms(100))
    XCTAssertEqual(transport.heldWriteCount, 1)

    _ = startStop()
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000"])

    transport.holdsWrites = false
    transport.releaseHeldWrites()
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000", "stop", "refStop"])

    await clock.advance(by: ms(300))
    await assertFinished(ticket, .failure(.interrupted))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000", "stop", "refStop"])
    XCTAssertEqual(transport.readTimes.count, 3)
  }

  func testStopDoesNotWaitForPendingRead() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1200, 40), sample(1210)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.settle()
    transport.holdsReads = true
    await clock.advance(by: ms(100))
    XCTAssertEqual(transport.heldReadCount, 1)

    _ = startStop()
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000", "stop", "refStop"])

    transport.holdsReads = false
    transport.releaseHeldReads()
    await clock.advance(by: ms(300))
    await assertFinished(ticket, .failure(.interrupted))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000", "stop", "refStop"])
    XCTAssertEqual(controller.state, .connected(.idle))
  }

  func testHungVerifyReadDoesNotBlockLaterStop() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1200, 40)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(150))
    _ = startStop()
    await clock.settle()
    transport.holdsReads = true
    await clock.advance(by: ms(300))
    XCTAssertEqual(transport.heldReadCount, 1)

    _ = startStop()
    await clock.advance(by: ms(999))
    XCTAssertFalse(ticket.isFinished)
    await clock.advance(by: ms(1))
    await assertFinished(ticket, .failure(.interrupted))
    await clock.advance(by: .seconds(5))
    XCTAssertEqual(
      log,
      ["wake", "stop", "T3000", "T3000", "stop", "refStop", "stop", "refStop", "stop", "refStop"])
    XCTAssertEqual(
      transport.writes.suffix(6).map(\.at), [150, 150, 1450, 1450, 1450, 1450].map(ms))
    transport.releaseHeldReads()
  }

  func testHungTickReadFailsMoveAndStops() async throws {
    transport.readScript = [sample(1000), sample(1100, 40)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.settle()
    transport.holdsReads = true
    await clock.advance(by: ms(1099))
    XCTAssertFalse(ticket.isFinished)
    await clock.advance(by: ms(1))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000", "stop", "refStop"])
    await clock.advance(by: ms(1300))

    await assertFinished(
      ticket,
      .failure(
        .moveFailed(.transport(String(describing: DeskTransportError.readFailed("timed out"))))))
    XCTAssertEqual(
      log, ["wake", "stop", "T3000", "T3000", "stop", "refStop", "stop", "refStop"])
    transport.releaseHeldReads()
  }

  func testTransportErrorMidMoveFailsAndStops() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1100)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.settle()
    let error = DeskTransportError.readFailed("boom")
    transport.nextReadError = error
    await clock.advance(by: ms(100))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000", "stop", "refStop"])
    await clock.advance(by: ms(300))

    await assertFinished(ticket, .failure(.moveFailed(.transport(String(describing: error)))))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000", "stop", "refStop"])
    assertWriteTypes()
  }

  func testWriteGoingStaleWhileQueuedIsDropped() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1100)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(50))
    let moveGeneration = controller.generation
    transport.holdsWrites = true
    let inFlight = Task {
      try await controller.send(
        Data([0x10, 0x00]), to: .referenceInput, type: .withoutResponse, generation: nil)
    }
    await clock.settle()
    let queued = Task {
      try await controller.send(
        Data([0x20, 0x00]), to: .referenceInput, type: .withoutResponse,
        generation: moveGeneration)
    }
    await clock.settle()
    XCTAssertEqual(transport.heldWriteCount, 1)

    _ = startStop()
    await clock.settle()
    XCTAssertNotEqual(controller.generation, moveGeneration)
    transport.holdsWrites = false
    transport.releaseHeldWrites()
    await clock.settle()

    let inFlightSent = try await inFlight.value
    let queuedSent = try await queued.value
    XCTAssertTrue(inFlightSent)
    XCTAssertFalse(queuedSent)
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T16", "stop", "refStop"])
    await clock.advance(by: ms(300))
    await assertFinished(ticket, .failure(.interrupted))
  }

  func testStaleGenerationWriteIsDropped() async throws {
    let current = controller.generation
    let dropped = try await controller.send(
      Data([0x10, 0x00]), to: .referenceInput, type: .withoutResponse, generation: current &+ 1)
    XCTAssertFalse(dropped)
    XCTAssertTrue(transport.writes.isEmpty)

    let sent = try await controller.send(
      Data([0x10, 0x00]), to: .referenceInput, type: .withoutResponse, generation: current)
    XCTAssertTrue(sent)
    let unguarded = try await controller.send(
      DeskCommand.stop.bytes, to: .control, type: .withResponse, generation: nil)
    XCTAssertTrue(unguarded)
    XCTAssertEqual(log, ["T16", "stop"])
  }

  func testInterruptingMoveThatSentNothingSkipsItsStop() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1100), sample(1100)]
    let first = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(50))
    let second = try controller.startMove(toRaw: 2000)
    let third = try controller.startMove(toRaw: 2500)
    await clock.advance(by: ms(300))
    await assertFinished(first, .failure(.interrupted))
    await assertFinished(second, .failure(.interrupted))
    XCTAssertEqual(
      log, ["wake", "stop", "T3000", "stop", "refStop", "wake", "stop", "T2500"])
    XCTAssertEqual(controller.currentMoveID, third.id)
  }

  func testExplicitStopAlwaysSendsStop() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1100), sample(1100)]
    _ = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(50))
    let second = try controller.startMove(toRaw: 2000)
    _ = startStop()
    await clock.advance(by: ms(600))
    await assertFinished(second, .failure(.interrupted))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "stop", "refStop", "stop", "refStop"])
  }

  func testStopWhileIdleSendsSingleStop() async throws {
    await controller.stop()
    XCTAssertEqual(log, ["stop", "refStop"])
    XCTAssertTrue(transport.readTimes.isEmpty)
  }

  func testNewMoveInterruptsOldAndStaleCancelIsHarmless() async throws {
    transport.readScript = [
      sample(1000), sample(1100, 40),
      sample(1150),
      sample(1150), sample(1500, 40), sample(1900, 40), sample(2000), sample(2000), sample(2001),
    ]
    let first = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(50))
    let second = try controller.startMove(toRaw: 2000)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 2000, id: second.id))))
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop", "T3000", "stop", "refStop"])

    await clock.advance(by: ms(300))
    await assertFinished(first, .failure(.interrupted))
    XCTAssertEqual(
      log, ["wake", "stop", "T3000", "stop", "refStop", "wake", "stop", "T2000"])

    await clock.advance(by: ms(50))
    await controller.cancel(moveID: first.id)
    XCTAssertEqual(controller.currentMoveID, second.id)

    await clock.advance(by: ms(1000))
    await assertFinished(second, .success(2001))
    XCTAssertEqual(
      log,
      ["wake", "stop", "T3000", "stop", "refStop", "wake", "stop"] + repeated("T2000", 4))
    XCTAssertEqual(activityLog, ["begin Moving the desk", "begin Moving the desk", "end", "end"])
  }

  func testNewMoveWaitsForStopOfInterruptedMoveWithInFlightWrite() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1150), sample(1150)]
    let first = try controller.startMove(toRaw: 3000)
    await clock.settle()
    transport.holdsWrites = true
    await clock.advance(by: ms(100))

    let second = try controller.startMove(toRaw: 2000)
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000"])

    transport.holdsWrites = false
    transport.releaseHeldWrites()
    await clock.advance(by: ms(300))
    await assertFinished(first, .failure(.interrupted))
    XCTAssertEqual(
      log, ["wake", "stop", "T3000", "T3000", "stop", "refStop", "wake", "stop", "T2000"])
    XCTAssertFalse(second.isFinished)
  }

  func testCancelByCurrentIDStopsMove() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1100)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(50))
    let cancelling = Task { await controller.cancel(moveID: ticket.id) }
    await clock.advance(by: ms(300))
    await cancelling.value
    await assertFinished(ticket, .failure(.interrupted))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "stop", "refStop"])
  }

  func testCancellingAwaitingTaskStopsMove() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1100)]
    let task = Task { try await controller.move(toRaw: 3000) }
    await clock.advance(by: ms(50))
    task.cancel()
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop", "T3000", "stop", "refStop"])
    await clock.advance(by: ms(300))
    XCTAssertNil(controller.currentMoveID)
    let result = await task.result
    if case .failure(let error) = result {
      XCTAssertEqual(error as? DeskControllerError, .interrupted)
    } else {
      XCTFail("move should be interrupted")
    }
  }

  // MARK: Relative moves

  func testMoveByIsRelativeToInFlightTarget() async throws {
    transport.push(sample(1000))
    await clock.settle()
    XCTAssertEqual(controller.heightRaw, 1000)

    let first = try controller.startMove(byRaw: 100)
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 1100, id: first.id))))
    let second = try controller.startMove(byRaw: 100)
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 1200, id: second.id))))
    let third = try controller.startMove(byRaw: 10_000)
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 6500, id: third.id))))
    let fourth = try controller.startMove(byRaw: -20_000)
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 0, id: fourth.id))))
    await clock.advance(by: ms(400))
    await assertFinished(first, .failure(.interrupted))
    await assertFinished(second, .failure(.interrupted))
    await assertFinished(third, .failure(.interrupted))
  }

  func testMoveByWithoutKnownHeightResolvesFromFirstRead() async throws {
    let ticket = try controller.startMove(byRaw: -300)
    XCTAssertEqual(controller.state, .connected(.moving(.relative(deltaRaw: -300, id: ticket.id))))
    XCTAssertEqual(controller.currentMoveID, ticket.id)
    transport.readScript = [sample(2000)]
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 1700, id: ticket.id))))
    XCTAssertEqual(log, ["wake", "stop", "T1700"])
  }

  func testMoveByAfterReconnectDoesNotUseStaleHeight() async throws {
    transport.push(sample(1000))
    await clock.settle()
    transport.setConnectionState(.disconnected)
    await clock.settle()
    XCTAssertNil(controller.heightRaw)
    XCTAssertEqual(controller.speedRaw, 0)
    transport.setConnectionState(.connected)
    await clock.settle()

    let first = try controller.startMove(byRaw: 100)
    let second = try controller.startMove(byRaw: 100)
    XCTAssertEqual(controller.state, .connected(.moving(.relative(deltaRaw: 200, id: second.id))))
    transport.readScript = [sample(4000)]
    await clock.settle()
    await assertFinished(first, .failure(.interrupted))
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 4200, id: second.id))))
    XCTAssertEqual(log, ["wake", "stop", "T4200"])
  }

  // MARK: Hold

  func testHoldReleaseEndsWithStop() async throws {
    transport.readScript = [
      sample(1000), sample(1100, 40), sample(1200, 40), sample(1300, 40), sample(1320),
    ]
    let input = TestHoldInput()
    let ticket = try controller.beginHold(.up, input: input)
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.moving(.hold(.up, id: ticket.id))))
    await clock.advance(by: ms(250))

    let ending = Task { await controller.endHold() }
    await clock.advance(by: ms(300))
    await ending.value
    await assertFinished(ticket, .success(1320))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T6500", 3) + ["stop", "refStop"])
    assertWriteTypes()
    XCTAssertEqual(controller.state, .connected(.idle))
  }

  func testHoldEndsWhenDeadManCheckFails() async throws {
    transport.readScript = [sample(3000), sample(2900, -40), sample(2800, -40), sample(2790)]
    let input = TestHoldInput()
    let ticket = try controller.beginHold(.down, input: input)
    await clock.advance(by: ms(150))
    input.isHeld = false
    await clock.advance(by: ms(50))
    XCTAssertEqual(log, ["wake", "stop", "T0", "T0", "stop", "refStop"])
    XCTAssertEqual(transport.writes.suffix(2).map(\.at), [200, 200].map(ms))

    await clock.advance(by: ms(300))
    await assertFinished(ticket, .success(2790))
    await clock.advance(by: .seconds(5))
    XCTAssertEqual(log, ["wake", "stop", "T0", "T0", "stop", "refStop"])
  }

  func testHoldIsCappedAtTwentySeconds() async throws {
    transport.readScript =
      [sample(1000)] + (1...200).map { sample(1000 + $0 * 5, 10) } + [sample(2000)]
    let input = TestHoldInput()
    let ticket = try controller.beginHold(.up, input: input)
    await clock.settle()
    await clock.advance(by: .seconds(19) + ms(900))
    XCTAssertFalse(ticket.isFinished)
    await clock.advance(by: ms(100))
    await clock.advance(by: ms(300))

    await assertFinished(ticket, .failure(.moveFailed(.holdTimeLimit)))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T6500", 200) + ["stop", "refStop"])
    XCTAssertTrue(input.isHeld)
  }

  func testHoldReleasedBeforeAnyHeightIsNotConnected() async throws {
    transport.holdsReads = true
    let ticket = try controller.beginHold(.up, input: TestHoldInput())
    await clock.settle()
    XCTAssertEqual(transport.heldReadCount, 1)
    await controller.endHold()
    await assertFinished(ticket, .failure(.notConnected))
    XCTAssertTrue(transport.writes.isEmpty)
    transport.releaseHeldReads()
  }

  func testHoldReachingLimitArrivesWithoutStop() async throws {
    transport.readScript = [
      sample(6300), sample(6400, 40), sample(6500), sample(6500), sample(6500),
    ]
    let ticket = try controller.beginHold(.up, input: TestHoldInput())
    await clock.advance(by: ms(700))
    await assertFinished(ticket, .success(6500))
    XCTAssertEqual(log, ["wake", "stop"] + repeated("T6500", 3))
  }

  func testHoldCommandPulseVariant() async throws {
    transport.readScript =
      [sample(1000)] + (1...7).map { sample(1000 + $0 * 50, 40) } + [sample(1400)]
    let ticket = try controller.beginHold(.up, input: TestHoldInput(), variant: .commandPulses)
    await clock.advance(by: ms(650))
    let ending = Task { await controller.endHold() }
    await clock.advance(by: ms(300))
    await ending.value
    await assertFinished(ticket, .success(1400))
    XCTAssertEqual(log, ["wake", "stop", "up", "up", "up", "stop", "refStop"])
    XCTAssertEqual(transport.writes[2...4].map(\.at), [0, 300, 600].map(ms))
    assertWriteTypes()
  }

  func testHoldDirectionSentinelVariant() async throws {
    transport.readScript = [sample(3000), sample(2950, -40), sample(2900)]
    let input = TestHoldInput()
    let ticket = try controller.beginHold(.down, input: input, variant: .directionSentinel)
    await clock.advance(by: ms(150))
    input.isHeld = false
    await clock.advance(by: ms(350))
    await assertFinished(ticket, .success(2900))
    XCTAssertEqual(log, ["wake", "stop", "dirDown", "dirDown", "stop", "refStop"])
    assertWriteTypes()
  }

  func testEndHoldDoesNotStopTargetMove() async throws {
    transport.readScript = [sample(1000), sample(1100, 40)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.settle()
    await controller.endHold()
    XCTAssertEqual(controller.currentMoveID, ticket.id)
    XCTAssertFalse(log.contains("refStop"))
  }

  // MARK: Connection and lifecycle

  func testDisconnectMidMoveFailsAndNeverResumes() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1200, 40)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(150))
    transport.setConnectionState(.disconnected)
    await clock.settle()
    XCTAssertEqual(controller.state, .disconnected)
    await clock.advance(by: ms(300))

    await assertFinished(ticket, .failure(.notConnected))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000"])
    XCTAssertEqual(transport.failedWrites.map(label), ["stop", "refStop", "stop", "refStop"])
    XCTAssertNil(controller.heightRaw)

    transport.setConnectionState(.connected)
    await clock.advance(by: .seconds(5))
    XCTAssertEqual(controller.state, .connected(.idle))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "T3000"])
    XCTAssertEqual(activityLog, ["begin Moving the desk", "end"])
  }

  func testSleepDuringMoveFailsWithNotConnected() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1150)]
    let ticket = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(50))
    let sleeping = Task { await controller.prepareForSleep() }
    await clock.advance(by: ms(300))
    await sleeping.value
    await assertFinished(ticket, .failure(.notConnected))
    XCTAssertEqual(log, ["wake", "stop", "T3000", "stop", "refStop"])
  }

  func testConnectionStatesMapToDeskState() async throws {
    let states: [(TransportConnectionState, DeskState)] = [
      (.poweredOff, .bluetoothOff), (.unauthorized, .unauthorized),
      (.scanning, .scanning), (.connecting, .connecting),
      (.pairingRequired(.pairingModeNeeded), .pairingRequired(.pairingModeNeeded)),
      (.disconnected, .disconnected), (.connected, .connected(.idle)),
    ]
    for (transportState, expected) in states {
      transport.setConnectionState(transportState)
      await clock.settle()
      XCTAssertEqual(controller.state, expected)
    }
  }

  func testMirrorsDiscoveredDesksAndBaseOffset() async throws {
    XCTAssertEqual(controller.baseMM, DeskHeight.defaultBaseMM)
    let desk = DiscoveredDesk(id: UUID(), name: "Desk 1234", rssi: -60)
    transport.publishDiscoveredDesks([desk])
    transport.publishBaseOffset(615.5)
    await clock.settle()
    XCTAssertEqual(controller.discoveredDesks, [desk])
    XCTAssertEqual(controller.baseMM, 615.5)

    controller.connect(to: desk.id)
    controller.connect()
    controller.handleWake()
    await controller.forgetDesk()
    await controller.disconnect()
    XCTAssertEqual(transport.connectToRequests, [desk.id])
    XCTAssertEqual(transport.connectRequests, 2)
    XCTAssertEqual(transport.forgetRequests, 1)
    XCTAssertEqual(transport.disconnectRequests, 1)
  }

  // MARK: Notifications

  func testExternalMovementDetectedFromNotifications() async throws {
    transport.push(sample(1000, 30))
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.moving(.external(.up))))
    XCTAssertNil(controller.currentMoveID)
    transport.push(sample(1050, -30))
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.moving(.external(.down))))
    transport.push(sample(1040, 0))
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.idle))
    XCTAssertEqual(controller.heightRaw, 1040)

    transport.push(sample(1100, 30))
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.moving(.external(.up))))
    await clock.advance(by: ms(900))
    XCTAssertEqual(controller.state, .connected(.moving(.external(.up))))
    await clock.advance(by: ms(100))
    XCTAssertEqual(controller.state, .connected(.idle))
    XCTAssertTrue(transport.readTimes.isEmpty)
    XCTAssertTrue(transport.writes.isEmpty)
  }

  func testWatchersEachReceiveSamplesAndStates() async throws {
    var received: [[DeskEvent]] = [[], []]
    let collectors = [controller.watch(), controller.watch()].enumerated().map { index, stream in
      Task {
        for await event in stream {
          received[index].append(event)
        }
      }
    }
    transport.push(sample(1000, 30))
    transport.push(sample(1010, 0))
    await clock.settle()
    for collector in collectors {
      collector.cancel()
    }

    let expected: [DeskEvent] = [
      .sample(sample(1000, 30)), .state(.connected(.moving(.external(.up)))),
      .sample(sample(1010, 0)), .state(.connected(.idle)),
    ]
    XCTAssertEqual(received, [expected, expected])
  }

  func testCoastAfterAppStopIsNotExternal() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1150)]
    _ = try controller.startMove(toRaw: 3000)
    await clock.advance(by: ms(50))
    _ = startStop()
    await clock.settle()
    transport.push(sample(1120, 40))
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.idle))

    await clock.advance(by: ms(300))
    transport.push(sample(1140, 20))
    await clock.advance(by: ms(1199))
    transport.push(sample(1145, 10))
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.idle))
    XCTAssertEqual(controller.heightRaw, 1145)

    await clock.advance(by: ms(1))
    transport.push(sample(1150, 30))
    await clock.settle()
    XCTAssertEqual(controller.state, .connected(.moving(.external(.up))))
  }

  func testSaveRightAfterHoldReleaseUsesCoastHeight() async throws {
    transport.readScript = [sample(1000), sample(1100, 40), sample(1200, 40), sample(1250, 10)]
    _ = try controller.beginHold(.up, input: TestHoldInput())
    await clock.advance(by: ms(150))
    let ending = Task { await controller.endHold() }
    await clock.advance(by: ms(300))
    await ending.value
    XCTAssertEqual(log.suffix(4), ["stop", "refStop", "stop", "refStop"])
    transport.push(sample(1262, 5))
    await clock.settle()

    let saved = try controller.savePosition(named: "Focus")
    XCTAssertEqual(saved.height.raw, 1262)
  }

  func testErrorWireCodes() {
    let codes: [(DeskControllerError, String)] = [
      (.notConnected, "notConnected"), (.outOfRange, "outOfRange"),
      (.interrupted, "interrupted"), (.deskMoving, "deskMoving"),
      (.moveFailed(.didNotStart), "moveFailed"), (.moveFailed(.holdTimeLimit), "moveFailed"),
      (.moveFailed(.transport("x")), "moveFailed"),
      (.positions(.unknownPosition), "unknownPosition"),
      (.positions(.invalidName(.numeric)), "invalidName"),
      (.positions(.invalidName(.numericSlug)), "invalidName"),
      (.positions(.duplicateName(clashingWith: "Sit")), "invalidName"),
      (.positions(.readOnly), "positionsReadOnly"), (.positions(.saveFailed("x")), "internal"),
    ]
    for (error, code) in codes {
      XCTAssertEqual(error.wireCode, code, "\(error)")
    }
  }

  // MARK: Positions

  func testMoveToPositionByName() async throws {
    let stand = try controller.positions.add(name: "Stand", height: DeskHeight(clamping: 5000))
    transport.readScript = [sample(1000)]
    let ticket = try controller.startMove(toPositionNamed: "stand")
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 5000, id: ticket.id))))
    let byID = try controller.startMove(toPositionID: stand.id)
    XCTAssertEqual(controller.state, .connected(.moving(.toTarget(raw: 5000, id: byID.id))))

    XCTAssertThrowsError(try controller.startMove(toPositionNamed: "Sit")) {
      XCTAssertEqual($0 as? DeskControllerError, .positions(.unknownPosition))
    }
    XCTAssertThrowsError(try controller.startMove(toPositionID: UUID())) {
      XCTAssertEqual($0 as? DeskControllerError, .positions(.unknownPosition))
    }
  }

  func testSaveCurrentPositionUsesSettledHeight() async throws {
    transport.readScript = [
      sample(1000), sample(1100, 40), sample(1200), sample(1200), sample(1203),
    ]
    let ticket = try controller.startMove(toRaw: 1200)
    await clock.settle()
    XCTAssertThrowsError(try controller.savePosition(named: "Focus")) {
      XCTAssertEqual($0 as? DeskControllerError, .deskMoving)
    }
    await clock.advance(by: ms(700))
    await assertFinished(ticket, .success(1203))

    let saved = try controller.savePosition(named: "Focus")
    XCTAssertEqual(saved.height.raw, 1203)
    let updated = try controller.savePosition(named: "focus", raw: 2000)
    XCTAssertEqual(updated.id, saved.id)
    XCTAssertEqual(controller.positions.positions.map(\.height.raw), [2000])
    XCTAssertThrowsError(try controller.savePosition(named: "Bad", raw: 7000)) {
      XCTAssertEqual($0 as? DeskControllerError, .outOfRange)
    }
    XCTAssertThrowsError(try controller.savePosition(named: "100", raw: 1000)) {
      XCTAssertEqual($0 as? DeskControllerError, .positions(.invalidName(.numeric)))
    }
  }

  func testReadOnlyPositionStoreSurfacesErrorAndControllerKeepsWorking() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    {"version":1,"positions":[{"id":"\(UUID().uuidString)","name":"Sit","raw":99999}]}
    """.write(to: directory.appending(path: "positions.json"), atomically: true, encoding: .utf8)
    controller = makeController()
    XCTAssertTrue(controller.positions.isReadOnly)

    XCTAssertThrowsError(try controller.savePosition(named: "Stand", raw: 5000)) {
      XCTAssertEqual($0 as? DeskControllerError, .positions(.readOnly))
    }
    transport.readScript = [sample(1000)]
    _ = try controller.startMove(toRaw: 2000)
    await clock.settle()
    XCTAssertEqual(log, ["wake", "stop", "T2000"])
  }

  private func runToCompletion(_ ticket: MoveTicket) async -> Result<Int, DeskControllerError>? {
    for _ in 0..<400 {
      if ticket.isFinished { break }
      await clock.advance(by: DeskController.tickInterval)
    }
    return await finished(ticket)
  }
}
