import DeskIPC
import DeskKit
import Foundation
import XCTest

@testable import IdasenCLI

private final class Output: @unchecked Sendable {
  private let lock = NSLock()
  private var outText = ""
  private var errText = ""

  var out: String { lock.withLock { outText } }
  var err: String { lock.withLock { errText } }

  func write(out text: String) { lock.withLock { outText += text } }
  func write(err text: String) { lock.withLock { errText += text } }
}

final class CLIEndToEndTests: ServerTestCase {
  private func idasen(
    _ arguments: [String], interrupt: (@Sendable () async -> Bool)? = nil
  ) async -> (status: Int32, output: Output) {
    let output = Output()
    let environment = CLIEnvironment(
      client: client,
      launchApp: { false },
      waitForInterrupt: interrupt ?? {
        try? await Task.sleep(for: .seconds(3600))
        return false
      },
      writeOut: { output.write(out: $0) },
      writeErr: { output.write(err: $0) },
      launchTimeout: .milliseconds(100), deskTimeout: .milliseconds(100),
      pollInterval: .milliseconds(5), socketPath: socketPath)
    let status = await executeIdasen(arguments: arguments, environment: environment)
    return (status, output)
  }

  func testStatusAndHeight() async throws {
    let status = await idasen(["status", "--json"])
    XCTAssertEqual(status.status, 0)
    XCTAssertEqual(
      status.output.out,
      #"{"heightCm":92,"maxCm":127,"minCm":62,"moving":false,"notFoundHint":false,"state":"connected"}"#
        + "\n")
    let height = await idasen(["height"])
    XCTAssertEqual(height.output.out, "92.0\n")
  }

  func testBlockingMovePrintsTheSettledHeight() async throws {
    async let result = idasen(["move", "82"])
    await eventually("move started") { desk.moves.count == 1 }
    desk.moves[0].ticket.resolve(.success(2000))
    let outcome = await result
    XCTAssertEqual(outcome.status, 0)
    XCTAssertEqual(outcome.output.out, "82.0\n")
  }

  func testCtrlCClosesTheConnectionWhichCancelsTheMove() async throws {
    let desk = desk!
    let result = await idasen(
      ["up", "5"],
      interrupt: {
        while await desk.moves.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        return true
      })
    XCTAssertEqual(result.status, 130)
    await eventually("cancel") { desk.cancelled == [desk.moves[0].ticket.id] }
  }

  func testInterruptedMoveExits8() async throws {
    async let result = idasen(["move", "Stand"])
    desk.storedPositions = [Position(name: "Stand", height: DeskHeight(clamping: 5000))]
    await eventually("move started") { desk.moves.count == 1 }
    desk.moves[0].ticket.resolve(.failure(.interrupted))
    let outcome = await result
    XCTAssertEqual(outcome.status, 8)
  }

  func testNoWaitMoveLeavesTheDeskMoving() async throws {
    let result = await idasen(["down", "2", "--no-wait"])
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(desk.moves.map(\.move), [.byRaw(-200)])
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(desk.cancelled.isEmpty)
  }

  func testAppNotRunningExits3() async throws {
    server.stop()
    let result = await idasen(["status", "--no-launch"])
    XCTAssertEqual(result.status, 3)
    XCTAssertTrue(result.output.err.contains(socketPath))
  }

  func testServerGoingAwayMidMoveExits11() async throws {
    async let result = idasen(["move", "82"])
    await eventually("move started") { desk.moves.count == 1 }
    server.stop()
    let outcome = await result
    XCTAssertEqual(outcome.status, 11)
  }

  func testWatchPrintsEventsUntilTheServerStops() async throws {
    async let result = idasen(["watch"])
    await eventually("watcher") { desk.watcherCount == 1 }
    desk.emit(.sample(HeightSample(heightRaw: 3500, speedRaw: 360)))
    desk.emit(.state(.disconnected))
    try await Task.sleep(for: .milliseconds(100))
    server.stop()
    let outcome = await result
    XCTAssertEqual(outcome.status, 11)
    XCTAssertEqual(
      outcome.output.out,
      "92.0 cm  connected  0.0 cm/s\n97.0 cm  connected  3.6 cm/s\nstate: disconnected\n")
  }
}
