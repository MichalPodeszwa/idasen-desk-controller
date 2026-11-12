import ArgumentParser
import DeskIPC
import Foundation
import XCTest

@testable import IdasenCLI

final class IdasenCLITests: XCTestCase {
  func testVersionString() {
    let info = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"]
    XCTAssertEqual(versionString(from: info), "1.2.3 (42)")
  }

  func testVersionStringWithoutInfoPlist() {
    XCTAssertEqual(versionString(from: nil), "unknown")
  }

  func testUsageErrorMapsToExitCode2() {
    XCTAssertEqual(exitStatus(for: ValidationError("bad")), 2)
  }

  func testSuccessAndFailureKeepTheirCodes() {
    XCTAssertEqual(exitStatus(for: CleanExit.message("ok")), 0)
    XCTAssertEqual(exitStatus(for: ExitCode(9)), 9)
  }
}

final class Capture: @unchecked Sendable {
  private let lock = NSLock()
  private var outText = ""
  private var errText = ""
  private var requestList: [Request] = []
  private var cancelledCount = 0
  private var launchCount = 0

  var out: String { lock.withLock { outText } }
  var err: String { lock.withLock { errText } }
  var requests: [Request] { lock.withLock { requestList } }
  var cancellations: Int { lock.withLock { cancelledCount } }
  var launches: Int { lock.withLock { launchCount } }

  func write(out text: String) { lock.withLock { outText += text } }
  func write(err text: String) { lock.withLock { errText += text } }
  func record(_ request: Request) { lock.withLock { requestList.append(request) } }
  func noteCancelled() { lock.withLock { cancelledCount += 1 } }
  func noteLaunch() { lock.withLock { launchCount += 1 } }
}

struct FakeClient: DeskIPCClient {
  let capture: Capture
  let handler: @Sendable (Request, Int) async throws -> Response
  let events: [Event]
  let counter = Counter()

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
      lock.withLock {
        value += 1
        return value
      }
    }
  }

  init(
    capture: Capture, events: [Event] = [],
    handler: @escaping @Sendable (Request, Int) async throws -> Response
  ) {
    self.capture = capture
    self.events = events
    self.handler = handler
  }

  func send(_ request: Request) async throws -> Response {
    capture.record(request)
    do {
      return try await handler(request, counter.next())
    } catch is CancellationError {
      capture.noteCancelled()
      throw CancellationError()
    }
  }

  func stream(_ request: Request) -> AsyncThrowingStream<ServerMessage, any Error> {
    capture.record(request)
    let attempt = counter.next()
    let events = events
    let handler = handler
    return AsyncThrowingStream { continuation in
      Task {
        do {
          let response = try await handler(request, attempt)
          if !response.ok { continuation.yield(.response(response)) }
          for event in events { continuation.yield(.event(event)) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }
}

final class IdasenCommandTests: XCTestCase {
  private let status = StatusPayload(
    state: .connected, moving: false, heightCm: 92.4, minCm: 62, maxCm: 127)

  private func run(
    _ arguments: [String], capture: Capture = Capture(), launches: Bool = true,
    interrupt: (@Sendable () async -> Bool)? = nil, events: [Event] = [],
    handler: @escaping @Sendable (Request, Int) async throws -> Response
  ) async -> (status: Int32, capture: Capture) {
    let environment = CLIEnvironment(
      client: FakeClient(capture: capture, events: events, handler: handler),
      launchApp: {
        capture.noteLaunch()
        return launches
      },
      waitForInterrupt: interrupt ?? {
        try? await Task.sleep(for: .seconds(3600))
        return false
      },
      writeOut: { capture.write(out: $0) },
      writeErr: { capture.write(err: $0) },
      launchTimeout: .milliseconds(300), deskTimeout: .milliseconds(300),
      pollInterval: .milliseconds(5), socketPath: "/tmp/test.sock")
    let status = await executeIdasen(arguments: arguments, environment: environment)
    return (status, capture)
  }

  private func ok(_ response: Response = .success)
    -> @Sendable (Request, Int) async throws -> Response
  {
    { _, _ in response }
  }

  func testParsingMapsEachCommandToItsRequest() async {
    let cases: [([String], Request)] = [
      (["status"], .status),
      (["height"], .status),
      (["move", "105.5"], .move(.heightCm(105.5), wait: true)),
      (["move", "110", "--no-wait"], .move(.heightCm(110), wait: false)),
      (["move", "Stand"], .move(.position("Stand"), wait: true)),
      (["move", "Deep work", "--no-wait"], .move(.position("Deep work"), wait: false)),
      (["move", "100,5"], .move(.position("100,5"), wait: true)),
      (["up"], .moveBy(deltaCm: 1, wait: true)),
      (["up", "2.5", "--no-wait"], .moveBy(deltaCm: 2.5, wait: false)),
      (["down"], .moveBy(deltaCm: -1, wait: true)),
      (["down", "3"], .moveBy(deltaCm: -3, wait: true)),
      (["stop"], .stop),
      (["positions"], .positionsList),
      (["positions", "--json"], .positionsList),
      (["positions", "list"], .positionsList),
      (
        ["positions", "save", "Focus", "--height", "100"],
        .positionsSave(name: "Focus", heightCm: 100)
      ),
      (["positions", "save", "Focus"], .positionsSave(name: "Focus", heightCm: nil)),
      (["positions", "remove", "Focus"], .positionsRemove(name: "Focus")),
      (
        ["positions", "rename", "Focus", "Deep work"],
        .positionsRename(from: "Focus", to: "Deep work")
      ),
      (["connect"], .connect),
    ]
    for (arguments, expected) in cases {
      let result = await run(arguments) { _, _ in
        Response(
          ok: true, heightCm: 92.4,
          status: StatusPayload(
            state: .connected, moving: false, heightCm: 92.4, minCm: 62, maxCm: 127),
          positions: [], position: PositionPayload(id: "1", name: "x", slug: "x", heightCm: 1))
      }
      XCTAssertEqual(result.status, 0, "\(arguments): \(result.capture.err)")
      XCTAssertEqual(result.capture.requests, [expected], "\(arguments)")
    }
  }

  func testWatchStreamsEvents() async {
    let result = await run(
      ["watch"],
      events: [.height(heightCm: 97.3, speedCmS: 3.6, state: .moving), .state(.disconnected)],
      handler: ok())
    XCTAssertEqual(result.capture.requests, [.watch])
    XCTAssertEqual(result.capture.out, "97.3 cm  moving  3.6 cm/s\nstate: disconnected\n")
    XCTAssertEqual(result.status, 11)
  }

  func testWatchJSONPrintsRawEvents() async {
    let result = await run(
      ["watch", "--json"], events: [.height(heightCm: 97.3, speedCmS: -3.6, state: .moving)],
      handler: ok())
    XCTAssertEqual(
      result.capture.out,
      #"{"event":"height","heightCm":97.3,"speedCmS":-3.6,"state":"moving"}"# + "\n")
  }

  func testUsageErrorsExitWith2() async {
    for arguments in [
      ["dance"], ["move"], ["up", "0"], ["down", "--", "-1"], ["status", "--bogus"],
      ["positions", "save"],
    ] {
      let result = await run(arguments, handler: ok())
      XCTAssertEqual(result.status, 2, "\(arguments)")
      XCTAssertTrue(result.capture.requests.isEmpty, "\(arguments)")
    }
  }

  func testServerErrorCodesMapToExitCodes() async {
    let expected: [(ErrorCode, Int32)] = [
      (.internal, 1), (.notConnected, 4), (.outOfRange, 5), (.unknownPosition, 6),
      (.moveFailed, 7), (.interrupted, 8), (.invalidName, 9), (.unsupportedVersion, 10),
      (.unsupported, 10), (.deskMoving, 12), (.positionsReadOnly, 13),
    ]
    for (code, status) in expected {
      let result = await run(["stop"], handler: ok(.failure(code, "boom")))
      XCTAssertEqual(result.status, status, "\(code)")
      XCTAssertTrue(result.capture.err.contains("boom"), "\(code)")
    }
  }

  func testVersionMismatchSuggestsRestart() async {
    let result = await run(
      ["status"], handler: ok(.failure(.unsupportedVersion, "Unsupported protocol version 2")))
    XCTAssertEqual(result.status, 10)
    XCTAssertTrue(result.capture.err.contains("restart Idasen"))
  }

  func testAppNotRunningWithNoLaunchExits3WithoutLaunching() async {
    for arguments in [["status", "--no-launch"], ["--no-launch", "status"]] {
      let result = await run(arguments) { _, _ in throw IPCClientError.unreachable }
      XCTAssertEqual(result.status, 3, "\(arguments)")
      XCTAssertEqual(result.capture.launches, 0)
      XCTAssertTrue(result.capture.err.contains("/tmp/test.sock"))
      XCTAssertEqual(result.capture.requests, [.status])
    }
  }

  func testLaunchFailureExits3() async {
    let result = await run(["status"], launches: false) { _, _ in throw IPCClientError.unreachable }
    XCTAssertEqual(result.status, 3)
    XCTAssertEqual(result.capture.launches, 1)
  }

  func testAutoLaunchThenSucceeds() async {
    let status = status
    let result = await run(["height"]) { _, attempt in
      if attempt < 4 { throw IPCClientError.unreachable }
      return Response(ok: true, status: status)
    }
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.capture.launches, 1)
    XCTAssertEqual(result.capture.out, "92.4\n")
  }

  func testAutoLaunchGivesUpAfterTheTimeout() async {
    let result = await run(["status"]) { _, _ in throw IPCClientError.unreachable }
    XCTAssertEqual(result.status, 3)
    XCTAssertEqual(result.capture.launches, 1)
  }

  func testTooLongSocketPathExits3WithoutLaunching() async {
    let result = await run(["status"]) { _, _ in throw IPCClientError.pathTooLong(length: 120) }
    XCTAssertEqual(result.status, 3)
    XCTAssertEqual(result.capture.launches, 0)
    XCTAssertTrue(result.capture.err.contains("too long"))
    XCTAssertTrue(result.capture.err.contains("IDASEN_SUPPORT_DIR"))
  }

  func testHeightWaitsForTheFirstHeightAfterConnecting() async {
    let status = status
    let noHeight = StatusPayload(
      state: .connected, moving: false, heightCm: nil, minCm: 62, maxCm: 127)
    let result = await run(["height"]) { _, attempt in
      Response(ok: true, status: attempt < 3 ? noHeight : status)
    }
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.capture.out, "92.4\n")
    XCTAssertEqual(result.capture.requests.count, 3)
  }

  func testLostConnectionExits11() async {
    let result = await run(["move", "100"]) { _, _ in throw IPCClientError.connectionLost }
    XCTAssertEqual(result.status, 11)
    XCTAssertEqual(result.capture.launches, 0)
  }

  func testHeightWaitsForTheDeskThenReportsNotConnected() async {
    let disconnected = StatusPayload(
      state: .connecting, moving: false, heightCm: nil, minCm: 62, maxCm: 127)
    let result = await run(["height"]) { _, _ in Response(ok: true, status: disconnected) }
    XCTAssertEqual(result.status, 4)
    XCTAssertGreaterThan(result.capture.requests.count, 1)

    let off = StatusPayload(
      state: .bluetoothOff, moving: false, heightCm: nil, minCm: 62, maxCm: 127)
    let immediate = await run(["height"]) { _, _ in Response(ok: true, status: off) }
    XCTAssertEqual(immediate.status, 4)
    XCTAssertEqual(immediate.capture.requests.count, 1)
  }

  func testWaitingMovePrintsSettledHeight() async {
    let result = await run(["move", "Stand"], handler: ok(Response(ok: true, heightCm: 112.04)))
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.capture.out, "112.0\n")
    let noWait = await run(["move", "Stand", "--no-wait"], handler: ok())
    XCTAssertEqual(noWait.capture.out, "")
  }

  func testCtrlCDuringWaitingMoveCancelsTheRequestAndExits130() async {
    let capture = Capture()
    let result = await run(
      ["move", "100"], capture: capture,
      interrupt: {
        while capture.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        return true
      },
      handler: { _, _ in
        try await Task.sleep(for: .seconds(3600))
        return .success
      })
    XCTAssertEqual(result.status, 130)
    XCTAssertEqual(capture.cancellations, 1)
    XCTAssertEqual(capture.err, "")
  }

  func testNoWaitMoveIsNotInterruptible() async {
    let capture = Capture()
    let result = await run(
      ["move", "100", "--no-wait"], capture: capture, interrupt: { true }, handler: ok())
    XCTAssertEqual(result.status, 0)
  }

  func testNonFiniteHeightIsOutOfRangeWithoutAServer() async {
    for text in ["inf", "-inf", "nan"] {
      let result = await run(["move", "--", text], handler: ok())
      XCTAssertEqual(result.status, 5, text)
      XCTAssertTrue(result.capture.requests.isEmpty)
    }
  }

  func testStatusOutput() async {
    let human = await run(["status"], handler: ok(Response(ok: true, status: status)))
    XCTAssertEqual(
      human.capture.out, "State:  connected\nHeight: 92.4 cm\nRange:  62.0–127.0 cm\n")
    let json = await run(["status", "--json"], handler: ok(Response(ok: true, status: status)))
    XCTAssertEqual(
      json.capture.out,
      #"{"heightCm":92.4,"maxCm":127,"minCm":62,"moving":false,"notFoundHint":false,"state":"connected"}"#
        + "\n")
  }

  func testStatusOutputShowsFailureAndNotFoundHint() async {
    let failed = StatusPayload(
      state: .failed, moving: false, heightCm: nil, minCm: 62, maxCm: 127,
      message: "Bluetooth error", notFoundHint: true)
    let human = await run(["status"], handler: ok(Response(ok: true, status: failed)))
    XCTAssertEqual(
      human.capture.out,
      "State:  failed (Bluetooth error)\nHeight: unknown\nRange:  62.0–127.0 cm\n"
        + "Desk not found: it may be off, out of range or connected to another device.\n")
    let json = await run(["status", "--json"], handler: ok(Response(ok: true, status: failed)))
    XCTAssertTrue(json.capture.out.contains(#""notFoundHint":true"#))
    XCTAssertTrue(json.capture.out.contains(#""state":"failed""#))
    let height = await run(["height"], handler: ok(Response(ok: true, status: failed)))
    XCTAssertEqual(height.status, 4)
    XCTAssertEqual(height.capture.requests.count, 1)
    XCTAssertTrue(height.capture.err.contains("Bluetooth error"))
  }

  func testWatchOutputShowsFailureAndNotFoundHint() async {
    let result = await run(
      ["watch"],
      events: [
        .state(.scanning, notFoundHint: true),
        .state(.failed, message: "Bluetooth error"),
      ], handler: ok())
    XCTAssertEqual(
      result.capture.out,
      "state: scanning\nDesk not found: it may be off, out of range or connected to another device.\n"
        + "state: failed (Bluetooth error)\n")
  }

  func testPositionsOutput() async {
    let positions = [
      PositionPayload(id: "1", name: "Sit", slug: "sit", heightCm: 72.5),
      PositionPayload(id: "2", name: "Żółte biurko", slug: "zolte-biurko", heightCm: 112),
      PositionPayload(id: "3", name: "🙂", slug: "", heightCm: 90),
    ]
    let human = await run(["positions"], handler: ok(Response(ok: true, positions: positions)))
    XCTAssertEqual(
      human.capture.out,
      "Sit  sit  72.5 cm\nŻółte biurko  zolte-biurko  112.0 cm\n🙂  -  90.0 cm\n")
    let json = await run(
      ["positions", "--json"], handler: ok(Response(ok: true, positions: positions)))
    XCTAssertEqual(
      json.capture.out,
      #"[{"heightCm":72.5,"id":"1","name":"Sit","slug":"sit"},"#
        + #"{"heightCm":112,"id":"2","name":"Żółte biurko","slug":"zolte-biurko"},"#
        + #"{"heightCm":90,"id":"3","name":"🙂","slug":""}]"# + "\n")
    let empty = await run(["positions"], handler: ok(Response(ok: true, positions: [])))
    XCTAssertEqual(empty.capture.out, "No positions saved.\n")
  }

  func testNumberFormattingIsLocaleIndependent() {
    XCTAssertEqual(Format.cm(92.44), "92.4")
    XCTAssertEqual(Format.cm(92.45), "92.5")
    XCTAssertEqual(Format.cm(100), "100.0")
    XCTAssertEqual(Format.cm(-0.04), "0.0")
    XCTAssertEqual(Format.cm(-1.26), "-1.3")
    XCTAssertEqual(Format.cm(0.05), "0.1")
  }

  func testEnclosingAppResolvesOnlyHelpersInsideAnApp() {
    XCTAssertEqual(
      AppLauncher.enclosingApp(
        forExecutable: URL(fileURLWithPath: "/Applications/Idasen.app/Contents/Helpers/idasen"))?
        .path,
      "/Applications/Idasen.app")
    XCTAssertNil(
      AppLauncher.enclosingApp(
        forExecutable: URL(fileURLWithPath: "/Applications/Idasen.app/Contents/MacOS/idasen")))
    XCTAssertNil(
      AppLauncher.enclosingApp(forExecutable: URL(fileURLWithPath: "/usr/local/bin/idasen")))
    XCTAssertNil(
      AppLauncher.enclosingApp(
        forExecutable: URL(fileURLWithPath: "/tmp/Helpers/idasen")))
  }

  func testAppBundleIdentifierFallback() {
    XCTAssertEqual(
      AppLauncher.appBundleIdentifier(cliBundleIdentifier: "io.github.michalpodeszwa.idasen.cli"),
      "io.github.michalpodeszwa.idasen")
    XCTAssertEqual(
      AppLauncher.appBundleIdentifier(
        cliBundleIdentifier: "io.github.michalpodeszwa.idasen.debug.cli"),
      "io.github.michalpodeszwa.idasen.debug")
  }
}
