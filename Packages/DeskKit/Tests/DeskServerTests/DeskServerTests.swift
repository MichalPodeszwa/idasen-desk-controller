import DeskIPC
import DeskKit
import DeskKitTestSupport
import Foundation
import XCTest

@testable import DeskServer

@MainActor
class ServerTestCase: XCTestCase {
  var directory: String!
  var socketPath: String { directory + "/control.sock" }
  var desk: FakeDesk!
  var server: ControlServer!
  var client: IPCClient { IPCClient(socketPath: socketPath) }

  override func setUp() async throws {
    let suffix = String(UInt32.random(in: 0...UInt32.max), radix: 36)
    directory = "/tmp/idk-\(suffix)"
    desk = FakeDesk()
    server = makeServer(desk: desk)
    try await server.start()
  }

  override func tearDown() async throws {
    server.stop()
    try? FileManager.default.removeItem(atPath: directory)
  }

  func makeServer(
    desk: any DeskControlling, connectTimeout: Duration = .milliseconds(200)
  ) -> ControlServer {
    ControlServer(desk: desk, socketPath: socketPath, connectTimeout: connectTimeout)
  }

  func eventually(
    _ description: String = "", timeout: Duration = .seconds(3),
    file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
  ) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      if ContinuousClock.now > deadline {
        return XCTFail("Timed out waiting for \(description)", file: file, line: line)
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  func raw(_ text: String) async throws -> ServerMessage {
    let connection = LineConnection(unixPath: socketPath)
    defer { connection.cancel() }
    try await connection.start()
    try await connection.send(Data((text + "\n").utf8))
    for try await line in connection.lines {
      return try ServerMessage.decode(line)
    }
    throw IPCClientError.connectionLost
  }

  func expectFailure(
    _ response: Response, _ code: ErrorCode, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(response.ok, file: file, line: line)
    XCTAssertEqual(response.error?.code, code, file: file, line: line)
  }
}

final class ControlServerRequestTests: ServerTestCase {
  func testStatusReportsStateAndRange() async throws {
    let response = try await client.send(.status)
    XCTAssertEqual(
      response,
      Response(
        ok: true,
        status: StatusPayload(
          state: .connected, moving: false, heightCm: 92.0, minCm: 62.0, maxCm: 127.0)))
  }

  func testStatusWithoutHeightAndWhileMoving() async throws {
    desk.heightRaw = nil
    desk.state = .disconnected
    var status = try await client.send(.status).status
    XCTAssertEqual(status?.state, .disconnected)
    XCTAssertNil(status?.heightCm)

    desk.heightRaw = 3050
    desk.state = .connected(.moving(.external(.up)))
    status = try await client.send(.status).status
    XCTAssertEqual(status?.state, .moving)
    XCTAssertEqual(status?.moving, true)
    XCTAssertEqual(status?.heightCm, 92.5)
  }

  func testStatusReportsFailureAndNotFoundHint() async throws {
    desk.heightRaw = nil
    desk.state = .failed("Bluetooth error")
    desk.notFoundHint = true
    let status = try await client.send(.status).status
    XCTAssertEqual(status?.state, .failed)
    XCTAssertEqual(status?.message, "Bluetooth error")
    XCTAssertEqual(status?.notFoundHint, true)

    desk.state = .disconnected
    desk.notFoundHint = false
    let healthy = try await client.send(.status).status
    XCTAssertEqual(healthy?.state, .disconnected)
    XCTAssertNil(healthy?.message)
    XCTAssertEqual(healthy?.notFoundHint, false)
  }

  func testCalibrationShiftsDisplayedHeights() async throws {
    server.stop()
    server = ControlServer(
      desk: desk, socketPath: socketPath, calibrationMM: { 5 },
      connectTimeout: .milliseconds(200))
    try await server.start()
    let status = try await client.send(.status).status
    XCTAssertEqual(status?.heightCm, 92.5)
    XCTAssertEqual(status?.minCm, 62.5)
  }

  func testMoveWaitReturnsSettledHeight() async throws {
    let request = Task { try await client.send(.move(.heightCm(82), wait: true)) }
    await eventually("move started") { desk.moves.count == 1 }
    XCTAssertEqual(desk.moves[0].move, .toRaw(2000))
    XCTAssertFalse(request.isCancelled)
    desk.moves[0].ticket.resolve(.success(2003))
    let response = try await request.value
    XCTAssertEqual(response, Response(ok: true, heightCm: 82.0))
  }

  func testMoveToPositionByName() async throws {
    desk.storedPositions = [Position(name: "Stand", height: DeskHeight(clamping: 5000))]
    let request = Task { try await client.send(.move(.position("stand"), wait: true)) }
    await eventually("move started") { desk.moves.count == 1 }
    XCTAssertEqual(desk.moves[0].move, .toPosition("stand"))
    desk.moves[0].ticket.resolve(.success(5000))
    let response = try await request.value
    XCTAssertEqual(response.heightCm, 112.0)
  }

  func testMoveToPositionBySlug() async throws {
    desk.storedPositions = [Position(name: "Żółte biurko", height: DeskHeight(clamping: 5000))]
    let request = Task { try await client.send(.move(.position("ZOLTE-biurko"), wait: true)) }
    await eventually("move started") { desk.moves.count == 1 }
    XCTAssertEqual(desk.moves[0].move, .toPosition("ZOLTE-biurko"))
    desk.moves[0].ticket.resolve(.success(5000))
    let settled = try await request.value
    XCTAssertEqual(settled.heightCm, 112.0)
    let unknown = try await client.send(.move(.position("zolte"), wait: true))
    expectFailure(unknown, .unknownPosition)
    XCTAssertEqual(desk.moves.count, 1)
  }

  func testPositionsListIncludesSlugs() async throws {
    desk.storedPositions = [
      Position(name: "Żółte biurko", height: DeskHeight(clamping: 5000)),
      Position(name: "🙂", height: DeskHeight(clamping: 1000)),
    ]
    let response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions?.map(\.slug), ["zolte-biurko", ""])
  }

  func testMoveNoWaitReturnsImmediately() async throws {
    let response = try await client.send(.move(.heightCm(100), wait: false))
    XCTAssertEqual(response, .success)
    XCTAssertEqual(desk.moves.count, 1)
    XCTAssertFalse(desk.moves[0].ticket.isResolved)
  }

  func testMoveByConvertsCentimetresToRawUnits() async throws {
    _ = try await client.send(.moveBy(deltaCm: -2.5, wait: false))
    XCTAssertEqual(desk.moves.map(\.move), [.byRaw(-250)])
  }

  func testAbsoluteOutOfRangeIsRejectedWithoutMoving() async throws {
    for cm in [127.1, 61.9, -5, 1e9] {
      expectFailure(try await client.send(.move(.heightCm(cm), wait: true)), .outOfRange)
    }
    XCTAssertTrue(desk.moves.isEmpty)
    let edge = try await client.send(.move(.heightCm(127), wait: false))
    XCTAssertTrue(edge.ok)
    XCTAssertEqual(desk.moves.map(\.move), [.toRaw(6500)])
  }

  func testUnknownPositionFailsBeforeWaitingForTheDesk() async throws {
    desk.state = .disconnected
    expectFailure(try await client.send(.move(.position("Nope"), wait: true)), .unknownPosition)
  }

  func testMoveFailureMapsToWireCode() async throws {
    let request = Task { try await client.send(.move(.heightCm(100), wait: true)) }
    await eventually("move started") { desk.moves.count == 1 }
    desk.moves[0].ticket.resolve(.failure(.moveFailed(.stalled)))
    let response = try await request.value
    expectFailure(response, .moveFailed)
    XCTAssertNotNil(response.error?.message)
  }

  func testControllerErrorsThrownAtStartMapToWireCodes() async throws {
    desk.moveError = .interrupted
    expectFailure(try await client.send(.moveBy(deltaCm: 1, wait: true)), .interrupted)
  }

  func testStopCallsDesk() async throws {
    let response = try await client.send(.stop)
    XCTAssertEqual(response, .success)
    XCTAssertEqual(desk.stopCount, 1)
  }

  func testCommandsWaitForConnection() async throws {
    desk.state = .connecting
    let request = Task { try await client.send(.move(.heightCm(100), wait: false)) }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(desk.moves.isEmpty)
    desk.emit(.state(.connected(.idle)))
    let response = try await request.value
    XCTAssertTrue(response.ok)
    XCTAssertEqual(desk.moves.count, 1)
  }

  func testCommandsFailWithNotConnectedAfterTimeout() async throws {
    desk.state = .disconnected
    expectFailure(try await client.send(.move(.heightCm(100), wait: true)), .notConnected)
    expectFailure(try await client.send(.moveBy(deltaCm: 1, wait: true)), .notConnected)
    expectFailure(try await client.send(.positionsSave(name: "Here", heightCm: nil)), .notConnected)
    XCTAssertTrue(desk.moves.isEmpty)
  }

  func testConnectRequestsConnectionAndWaits() async throws {
    desk.state = .disconnected
    let request = Task { try await client.send(.connect) }
    await eventually("connect requested") { desk.connectCalls == 1 }
    desk.emit(.state(.connected(.idle)))
    let response = try await request.value
    XCTAssertEqual(response, .success)

    expectFailure(
      try await {
        desk.state = .disconnected
        return try await client.send(.connect)
      }(),
      .notConnected)
  }

  func testPositionsSaveWithHeightAndSettled() async throws {
    let explicit = try await client.send(.positionsSave(name: "Focus", heightCm: 100))
    XCTAssertEqual(explicit.position?.name, "Focus")
    XCTAssertEqual(explicit.position?.heightCm, 100.0)
    let settled = try await client.send(.positionsSave(name: "Here", heightCm: nil))
    XCTAssertEqual(settled.position?.heightCm, 92.0)
    expectFailure(
      try await client.send(.positionsSave(name: "Far", heightCm: 300)), .outOfRange)
    let list = try await client.send(.positionsList)
    XCTAssertEqual(list.positions?.map(\.name), ["Focus", "Here"])
    XCTAssertEqual(list.positions?.map(\.heightCm), [100.0, 92.0])
    XCTAssertEqual(list.positions?.first?.id, desk.storedPositions[0].id.uuidString)
  }

  func testUnsupportedCommand() async throws {
    let message = try await raw(#"{"v":1,"cmd":"dance"}"#)
    guard case .response(let response) = message else { return XCTFail("\(message)") }
    expectFailure(response, .unsupported)
  }

  func testUnknownMajorVersion() async throws {
    let message = try await raw(#"{"v":2,"cmd":"status"}"#)
    guard case .response(let response) = message else { return XCTFail("\(message)") }
    expectFailure(response, .unsupportedVersion)
  }

  func testUnknownFieldsAreIgnored() async throws {
    let message = try await raw(#"{"v":1,"cmd":"status","extra":{"x":1}}"#)
    guard case .response(let response) = message else { return XCTFail("\(message)") }
    XCTAssertTrue(response.ok)
  }

  func testMalformedRequestsFailWithoutKillingTheServer() async throws {
    for text in ["not json", #"{"v":1,"cmd":"move"}"#] {
      guard case .response(let response) = try await raw(text) else { return XCTFail(text) }
      expectFailure(response, .internal)
    }
    let ok = try await client.send(.status).ok
    XCTAssertTrue(ok)
  }

  func testOverlongRequestLineIsRejected() async throws {
    let connection = LineConnection(unixPath: socketPath)
    defer { connection.cancel() }
    try await connection.start()
    try await connection.send(Data(repeating: 0x61, count: 70 * 1024))
    var received: ServerMessage?
    for try await line in connection.lines {
      received = try ServerMessage.decode(line)
      break
    }
    guard case .response(let response) = received else {
      return XCTFail("\(String(describing: received))")
    }
    expectFailure(response, .internal)
  }

  func testWireCodesOfEveryControllerErrorAreKnownErrorCodes() {
    let errors: [DeskControllerError] = [
      .notConnected, .outOfRange, .interrupted, .deskMoving,
      .moveFailed(.didNotStart), .moveFailed(.stalled), .moveFailed(.timedOut),
      .moveFailed(.holdTimeLimit), .moveFailed(.transport("x")),
      .positions(.unknownPosition), .positions(.invalidName(.empty)),
      .positions(.invalidName(.numeric)), .positions(.invalidName(.numericSlug)),
      .positions(.duplicateName(clashingWith: "Sit")), .positions(.readOnly),
      .positions(.saveFailed("x")),
    ]
    for error in errors {
      let code = ErrorCode(rawValue: error.wireCode)
      XCTAssertNotNil(code, "\(error)")
    }
    XCTAssertEqual(DeskControllerError.positions(.saveFailed("x")).wireCode, "internal")
  }
}

final class ControlServerCancellationTests: ServerTestCase {
  func testDisconnectCancelsOwnWaitingMove() async throws {
    let request = Task { try await client.send(.move(.heightCm(100), wait: true)) }
    await eventually("move started") { desk.moves.count == 1 }
    request.cancel()
    await eventually("cancel") { desk.cancelled == [desk.moves[0].ticket.id] }
  }

  func testDisconnectNeverCancelsANewerMove() async throws {
    let first = Task { try await client.send(.move(.heightCm(100), wait: true)) }
    await eventually("first move") { desk.moves.count == 1 }
    _ = try await client.send(.move(.heightCm(110), wait: false))
    XCTAssertEqual(desk.moves.count, 2)
    first.cancel()
    await eventually("cancel") { !desk.cancelled.isEmpty }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(desk.cancelled, [desk.moves[0].ticket.id])
  }

  func testNoWaitMoveSurvivesDisconnect() async throws {
    _ = try await client.send(.move(.heightCm(100), wait: false))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(desk.cancelled.isEmpty)
  }

  func testWaitingMoveThatFinishedIsNotCancelledByTheCloseAfterReply() async throws {
    let request = Task { try await client.send(.move(.heightCm(100), wait: true)) }
    await eventually("move started") { desk.moves.count == 1 }
    desk.moves[0].ticket.resolve(.success(2000))
    _ = try await request.value
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(desk.cancelled.isEmpty)
  }

  func testDisconnectWhileWaitingForTheDeskNeverStartsTheMove() async throws {
    server.stop()
    server = makeServer(desk: desk, connectTimeout: .seconds(5))
    try await server.start()
    desk.state = .connecting
    let request = Task { try await client.send(.move(.heightCm(100), wait: true)) }
    await eventually("watching for the desk") { desk.watcherCount == 1 }
    request.cancel()
    await eventually("watcher released") { desk.watcherCount == 0 }
    desk.emit(.state(.connected(.idle)))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(desk.moves.isEmpty)
    XCTAssertTrue(desk.cancelled.isEmpty)
  }

  func testNoWaitMoveStillStartsAfterTheDeskConnects() async throws {
    server.stop()
    server = makeServer(desk: desk, connectTimeout: .seconds(5))
    try await server.start()
    desk.state = .connecting
    let request = Task { try await client.send(.moveBy(deltaCm: 1, wait: false)) }
    await eventually("watching for the desk") { desk.watcherCount == 1 }
    desk.emit(.state(.connected(.idle)))
    let response = try await request.value
    XCTAssertEqual(response, .success)
    XCTAssertEqual(desk.moves.map(\.move), [.byRaw(100)])
  }

  func testHalfCloseCountsAsDisconnectAndCancelsTheWaitingMove() async throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in socketPath.utf8.enumerated() { buffer[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(connected, 0)
    let line = Array(#"{"v":1,"cmd":"move","target":{"heightCm":100},"wait":true}"#.utf8 + [10])
    XCTAssertEqual(write(descriptor, line, line.count), line.count)
    await eventually("move started") { desk.moves.count == 1 }
    XCTAssertEqual(shutdown(descriptor, SHUT_WR), 0)
    await eventually("cancel") { desk.cancelled == [desk.moves[0].ticket.id] }
  }

  func testProbeConnectionWithNoRequestChangesNothing() async throws {
    let request = Task { try await client.send(.move(.heightCm(100), wait: true)) }
    await eventually("move started") { desk.moves.count == 1 }
    XCTAssertEqual(try SocketPath.probe(path: socketPath), .live)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(desk.cancelled.isEmpty)
    desk.moves[0].ticket.resolve(.success(2000))
    let ok = try await request.value.ok
    XCTAssertTrue(ok)
  }

  func testWatchDisconnectCancelsNothingAndReleasesTheWatcher() async throws {
    _ = try await client.send(.move(.heightCm(100), wait: false))
    let stream = Task {
      for try await _ in client.stream(.watch) {}
    }
    await eventually("watcher") { desk.watcherCount == 1 }
    stream.cancel()
    await eventually("watcher released") { desk.watcherCount == 0 }
    XCTAssertTrue(desk.cancelled.isEmpty)
  }
}

final class ControlServerWatchTests: ServerTestCase {
  func testWatchStreamsSnapshotThenEvents() async throws {
    var iterator = client.stream(.watch).makeAsyncIterator()
    let first = try await iterator.next()
    XCTAssertEqual(first, .event(.height(heightCm: 92.0, speedCmS: 0, state: .connected)))

    desk.emit(.state(.connected(.moving(.external(.up)))))
    desk.emit(.sample(HeightSample(heightRaw: 3500, speedRaw: 360)))
    desk.emit(.sample(HeightSample(heightRaw: 3510, speedRaw: -125)))
    desk.emit(.state(.disconnected))
    let events = [
      try await iterator.next(), try await iterator.next(), try await iterator.next(),
      try await iterator.next(),
    ]
    XCTAssertEqual(
      events,
      [
        .event(.state(.moving)),
        .event(.height(heightCm: 97.0, speedCmS: 3.6, state: .moving)),
        .event(.height(heightCm: 97.1, speedCmS: -1.3, state: .moving)),
        .event(.state(.disconnected)),
      ])
  }

  func testWatchSnapshotWithoutHeightIsAStateEvent() async throws {
    desk.heightRaw = nil
    desk.state = .scanning
    var iterator = client.stream(.watch).makeAsyncIterator()
    let first = try await iterator.next()
    XCTAssertEqual(first, .event(.state(.scanning)))
  }

  func testWatchStateEventsCarryFailureAndNotFoundHint() async throws {
    desk.heightRaw = nil
    desk.state = .scanning
    var iterator = client.stream(.watch).makeAsyncIterator()
    _ = try await iterator.next()
    desk.notFoundHint = true
    desk.emit(.notFoundHint(true))
    let hint = try await iterator.next()
    desk.emit(.state(.failed("Bluetooth error")))
    let failed = try await iterator.next()
    XCTAssertEqual(hint, .event(.state(.scanning, notFoundHint: true)))
    XCTAssertEqual(
      failed, .event(.state(.failed, message: "Bluetooth error", notFoundHint: true)))
  }

  func testStoppingTheServerEndsWatchStreams() async throws {
    var iterator = client.stream(.watch).makeAsyncIterator()
    _ = try await iterator.next()
    server.stop()
    do {
      let next = try await iterator.next()
      XCTAssertNil(next)
    } catch {
      XCTAssertEqual(error as? IPCClientError, .connectionLost)
    }
  }
}

final class ControlServerLifecycleTests: ServerTestCase {
  private func mode(_ path: String) throws -> Int {
    var info = stat()
    XCTAssertEqual(stat(path, &info), 0)
    return Int(info.st_mode & 0o777)
  }

  func testSocketIsOwnerOnlyAndDirectoryIsPrivate() throws {
    XCTAssertEqual(try mode(socketPath), 0o600)
    XCTAssertEqual(try mode(directory), 0o700)
  }

  func testStopUnlinksTheSocket() throws {
    XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
  }

  func testSecondInstanceIsDetectedAndLeavesTheFirstRunning() async throws {
    let second = ControlServer(desk: FakeDesk(), socketPath: socketPath)
    do {
      try await second.start()
      XCTFail("expected alreadyRunning")
    } catch {
      XCTAssertEqual(error, .alreadyRunning)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    let ok1 = try await client.send(.status).ok
    XCTAssertTrue(ok1)
    second.stop()
    let ok2 = try await client.send(.status).ok
    XCTAssertTrue(ok2)
  }

  func testStaleSocketIsCleanedUp() async throws {
    server.stop()
    try Self.makeStaleSocket(at: socketPath)
    XCTAssertEqual(try SocketPath.probe(path: socketPath), .stale)
    server = makeServer(desk: desk)
    try await server.start()
    let ok = try await client.send(.status).ok
    XCTAssertTrue(ok)
  }

  func testPathTooLong() async throws {
    let long = "/tmp/" + String(repeating: "a", count: 110) + "/control.sock"
    let tooLong = ControlServer(desk: desk, socketPath: long)
    do {
      try await tooLong.start()
      XCTFail("expected pathTooLong")
    } catch {
      XCTAssertEqual(error, .pathTooLong(length: long.utf8.count))
    }
  }

  func testStartCreatesMissingDirectories() async throws {
    server.stop()
    try? FileManager.default.removeItem(atPath: directory)
    server = makeServer(desk: desk)
    try await server.start()
    XCTAssertEqual(try mode(directory), 0o700)
  }

  func testStopDuringStartLeavesNothingListening() async throws {
    server.stop()
    let second = makeServer(desk: desk)
    let starting = Task { @MainActor in
      do throws(ControlServer.StartError) {
        try await second.start()
        return nil as ControlServer.StartError?
      } catch {
        return error
      }
    }
    await Task.yield()
    second.stop()
    let error = await starting.value
    XCTAssertEqual(error, .stopped)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    do {
      _ = try await client.send(.status)
      XCTFail("expected unreachable")
    } catch {
      XCTAssertEqual(error as? IPCClientError, .unreachable)
    }
  }

  func testClientReportsATooLongPathInsteadOfUnreachable() async throws {
    let long = "/tmp/" + String(repeating: "a", count: 110) + "/control.sock"
    do {
      _ = try await IPCClient(socketPath: long).send(.status)
      XCTFail("expected pathTooLong")
    } catch {
      XCTAssertEqual(error as? IPCClientError, .pathTooLong(length: long.utf8.count))
    }
  }

  func testClientReportsUnreachableWhenNoServerRuns() async throws {
    server.stop()
    do {
      _ = try await client.send(.status)
      XCTFail("expected unreachable")
    } catch {
      XCTAssertEqual(error as? IPCClientError, .unreachable)
    }
  }

  static func makeStaleSocket(at path: String) throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(result, 0)
  }
}

@MainActor
final class ControlServerDeskControllerTests: XCTestCase {
  private var directory: String!
  private var transport: FakeTransport!
  private var controller: DeskController!
  private var server: ControlServer!
  private var client: IPCClient { IPCClient(socketPath: directory + "/control.sock") }

  override func setUp() async throws {
    directory = "/tmp/idk-\(String(UInt32.random(in: 0...UInt32.max), radix: 36))"
    transport = FakeTransport(restingSample: HeightSample(heightRaw: 1000, speedRaw: 0))
    controller = DeskController(
      transport: transport,
      positions: PositionStore(directory: URL(fileURLWithPath: directory + "/data")))
    transport.push(HeightSample(heightRaw: 1000, speedRaw: 0))
    try await Task.sleep(for: .milliseconds(50))
    server = ControlServer(
      desk: controller, socketPath: directory + "/control.sock", connectTimeout: .milliseconds(100))
    try await server.start()
  }

  override func tearDown() async throws {
    server.stop()
    try? FileManager.default.removeItem(atPath: directory)
  }

  func testPositionsLifecycleThroughTheRealController() async throws {
    var response = try await client.send(.positionsSave(name: "Sit", heightCm: 72.5))
    XCTAssertEqual(response.position?.heightCm, 72.5)
    response = try await client.send(.positionsSave(name: "sit", heightCm: 80))
    XCTAssertEqual(response.position?.heightCm, 80.0)
    response = try await client.send(.positionsSave(name: "Here", heightCm: nil))
    XCTAssertEqual(response.position?.heightCm, 72.0)

    response = try await client.send(.positionsRename(from: "Here", to: "Desk"))
    XCTAssertEqual(response, .success)
    response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions?.map(\.name), ["Sit", "Desk"])

    response = try await client.send(.positionsRemove(name: "desk"))
    XCTAssertEqual(response, .success)
    response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions?.map(\.name), ["Sit"])
  }

  func testPositionsAddressableBySlugThroughTheRealController() async throws {
    var response = try await client.send(.positionsSave(name: "Żółte biurko", heightCm: 80))
    XCTAssertEqual(response.position?.slug, "zolte-biurko")
    response = try await client.send(.positionsSave(name: "Zolte-Biurko", heightCm: 90))
    XCTAssertEqual(response.error?.code, .invalidName)
    XCTAssertTrue(response.error?.message.contains("Żółte biurko") == true)

    response = try await client.send(.move(.position("zolte-biurko"), wait: false))
    XCTAssertEqual(response, .success)

    response = try await client.send(.positionsRename(from: "zolte-biurko", to: "Standing"))
    XCTAssertEqual(response, .success)
    response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions?.map(\.slug), ["standing"])
    response = try await client.send(.positionsRemove(name: "STANDING"))
    XCTAssertEqual(response, .success)
    response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions, [])
  }

  func testPositionErrorsMapToWireCodes() async throws {
    var response = try await client.send(.positionsRemove(name: "Nope"))
    XCTAssertEqual(response.error?.code, .unknownPosition)
    response = try await client.send(.positionsSave(name: "100.5", heightCm: 80))
    XCTAssertEqual(response.error?.code, .invalidName)
    _ = try await client.send(.positionsSave(name: "A", heightCm: 80))
    _ = try await client.send(.positionsSave(name: "B", heightCm: 90))
    response = try await client.send(.positionsRename(from: "A", to: "b"))
    XCTAssertEqual(response.error?.code, .invalidName)
    response = try await client.send(.move(.position("Nope"), wait: true))
    XCTAssertEqual(response.error?.code, .unknownPosition)
  }

  func testStatusAndRealMoveStart() async throws {
    let status = try await client.send(.status).status
    XCTAssertEqual(status?.heightCm, 72.0)
    XCTAssertEqual(status?.state, .connected)

    let response = try await client.send(.move(.heightCm(500), wait: true))
    XCTAssertEqual(response.error?.code, .outOfRange)
  }

  func testWatchReportsRealControllerFailureAndNotFoundHint() async throws {
    var iterator = client.stream(.watch).makeAsyncIterator()
    let snapshot = try await iterator.next()
    XCTAssertEqual(snapshot, .event(.height(heightCm: 72.0, speedCmS: 0, state: .connected)))

    transport.setConnectionState(.scanning)
    let scanning = try await iterator.next()
    XCTAssertEqual(scanning, .event(.state(.scanning)))
    transport.publishNotFoundHint(true)
    let hint = try await iterator.next()
    XCTAssertEqual(hint, .event(.state(.scanning, notFoundHint: true)))
    transport.publishNotFoundHint(true)
    transport.setConnectionState(.failed("Missing characteristic"))
    let failed = try await iterator.next()
    XCTAssertEqual(
      failed,
      .event(.state(.failed, message: "Missing characteristic", notFoundHint: true)))

    let status = try await client.send(.status).status
    XCTAssertEqual(status?.state, .failed)
    XCTAssertEqual(status?.message, "Missing characteristic")
    XCTAssertEqual(status?.notFoundHint, true)
  }

  func testSettledHeightWhileMovingIsDeskMoving() async throws {
    _ = try await client.send(.move(.heightCm(100), wait: false))
    let response = try await client.send(.positionsSave(name: "Now", heightCm: nil))
    XCTAssertEqual(response.error?.code, .deskMoving)
    _ = try await client.send(.stop)
  }
}

@MainActor
final class ControlServerPlantedPositionsTests: XCTestCase {
  private var directory: String!
  private var transport: FakeTransport!
  private var controller: DeskController!
  private var server: ControlServer!
  private var client: IPCClient { IPCClient(socketPath: directory + "/control.sock") }

  override func setUp() async throws {
    directory = "/tmp/idk-\(String(UInt32.random(in: 0...UInt32.max), radix: 36))"
  }

  override func tearDown() async throws {
    server?.stop()
    try? FileManager.default.removeItem(atPath: directory)
  }

  private func start(planting entries: [(name: String, raw: Int)]) async throws {
    try FileManager.default.createDirectory(
      atPath: directory + "/data", withIntermediateDirectories: true)
    let positions = entries.enumerated().map { index, entry in
      #"{"id": "6F1C0000-0000-4000-8000-00000000000\#(index + 1)", "name": "\#(entry.name)", "raw": \#(entry.raw)}"#
    }
    try #"{"version": 1, "positions": [\#(positions.joined(separator: ","))]}"#
      .write(toFile: directory + "/data/positions.json", atomically: true, encoding: .utf8)
    transport = FakeTransport(restingSample: HeightSample(heightRaw: 1000, speedRaw: 0))
    controller = DeskController(
      transport: transport,
      positions: PositionStore(directory: URL(fileURLWithPath: directory + "/data")))
    transport.push(HeightSample(heightRaw: 1000, speedRaw: 0))
    try await Task.sleep(for: .milliseconds(50))
    server = ControlServer(
      desk: controller, socketPath: directory + "/control.sock", connectTimeout: .milliseconds(100))
    try await server.start()
  }

  private var targetRaw: Int? {
    guard case .connected(.moving(.toTarget(let raw, _))) = controller.state else { return nil }
    return raw
  }

  func testAmbiguousSlugMatchesNothingButNamesStillMatch() async throws {
    try await start(planting: [("Żółte", 2000), ("Zolte!", 3000), ("Standing", 4000)])
    XCTAssertFalse(controller.positions.isReadOnly)

    var response = try await client.send(.move(.position("zolte"), wait: false))
    XCTAssertEqual(response.error?.code, .unknownPosition)
    XCTAssertNil(targetRaw)

    response = try await client.send(.move(.position("Żółte"), wait: false))
    XCTAssertEqual(response, .success)
    XCTAssertEqual(targetRaw, 2000)
    response = try await client.send(.move(.position("ZOLTE!"), wait: false))
    XCTAssertEqual(response, .success)
    XCTAssertEqual(targetRaw, 3000)

    response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions?.map(\.slug), ["", "", "standing"])
    response = try await client.send(.positionsRename(from: "zolte", to: "x"))
    XCTAssertEqual(response.error?.code, .unknownPosition)
    response = try await client.send(.positionsRename(from: "Zolte!", to: "Spokój"))
    XCTAssertEqual(response, .success)
    response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions?.map(\.slug), ["zolte", "spokoj", "standing"])
  }

  func testNumericSlugPositionIsVisibleAndMovableByName() async throws {
    try await start(planting: [("#1", 2000)])
    XCTAssertFalse(controller.positions.isReadOnly)
    var response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions?.map(\.name), ["#1"])
    XCTAssertEqual(response.positions?.map(\.slug), [""])
    response = try await client.send(.move(.position("#1"), wait: false))
    XCTAssertEqual(response, .success)
    XCTAssertEqual(targetRaw, 2000)
  }

  func testNameBeatsSlugOverAPlantedFile() async throws {
    try await start(planting: [("Żółte biurko", 2000), ("zolte-biurko", 3000)])
    XCTAssertFalse(controller.positions.isReadOnly)
    var response = try await client.send(.move(.position("zolte-biurko"), wait: false))
    XCTAssertEqual(response, .success)
    XCTAssertEqual(targetRaw, 3000)
    response = try await client.send(.move(.position("Żółte biurko"), wait: false))
    XCTAssertEqual(response, .success)
    XCTAssertEqual(targetRaw, 2000)
  }

  func testReadOnlyFileKeepsValidPositionsMovable() async throws {
    try await start(planting: [("Sit", 7000), ("Stand", 4000)])
    XCTAssertTrue(controller.positions.isReadOnly)
    var response = try await client.send(.positionsList)
    XCTAssertEqual(response.positions?.map(\.name), ["Stand"])
    response = try await client.send(.move(.position("stand"), wait: false))
    XCTAssertEqual(response, .success)
    XCTAssertEqual(targetRaw, 4000)
    response = try await client.send(.positionsRemove(name: "Stand"))
    XCTAssertEqual(response.error?.code, .positionsReadOnly)
  }
}
