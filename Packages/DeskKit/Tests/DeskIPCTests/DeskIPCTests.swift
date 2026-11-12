import Foundation
import XCTest

@testable import DeskIPC

final class DeskIPCTests: XCTestCase {
  func testProtocolVersion() {
    XCTAssertEqual(DeskIPC.protocolVersion, 1)
  }

  private func json(_ data: Data) throws -> [String: Any] {
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(text.hasSuffix("\n"))
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try XCTUnwrap(object as? [String: Any])
  }

  func testEveryRequestRoundTrips() throws {
    let requests: [Request] = [
      .status,
      .move(.heightCm(110), wait: true),
      .move(.position("Stand"), wait: false),
      .moveBy(deltaCm: -2, wait: true),
      .moveBy(deltaCm: 0.5, wait: false),
      .stop,
      .positionsList,
      .positionsSave(name: "Focus", heightCm: 100),
      .positionsSave(name: "Focus", heightCm: nil),
      .positionsRemove(name: "Focus"),
      .positionsRename(from: "Focus", to: "Deep work"),
      .connect,
      .watch,
    ]
    for request in requests {
      XCTAssertEqual(try Request.decode(request.encodedLine()), request)
    }
  }

  func testRequestEncodingMatchesDocumentedShapes() throws {
    let move = try json(Request.move(.position("Stand"), wait: false).encodedLine())
    XCTAssertEqual(move["v"] as? Int, 1)
    XCTAssertEqual(move["cmd"] as? String, "move")
    XCTAssertEqual((move["target"] as? [String: Any])?["position"] as? String, "Stand")
    XCTAssertEqual(move["wait"] as? Bool, false)

    let rename = try json(Request.positionsRename(from: "Focus", to: "Deep work").encodedLine())
    XCTAssertEqual(rename["cmd"] as? String, "positions.rename")
    XCTAssertEqual(rename["from"] as? String, "Focus")
    XCTAssertEqual(rename["to"] as? String, "Deep work")

    let height = try json(Request.move(.heightCm(110), wait: true).encodedLine())
    XCTAssertEqual((height["target"] as? [String: Any])?["heightCm"] as? Double, 110)
    XCTAssertEqual(try Request.status.encodedLine(), Data(#"{"cmd":"status","v":1}"#.utf8 + [10]))
  }

  func testDecodingDocumentedRequests() throws {
    let cases: [(String, Request)] = [
      (#"{"v":1,"cmd":"status"}"#, .status),
      (
        #"{"v":1,"cmd":"move","target":{"heightCm":110},"wait":true}"#,
        .move(.heightCm(110), wait: true)
      ),
      (#"{"v":1,"cmd":"moveBy","deltaCm":-2,"wait":true}"#, .moveBy(deltaCm: -2, wait: true)),
      (
        #"{"v":1,"cmd":"positions.save","name":"Focus","heightCm":100}"#,
        .positionsSave(name: "Focus", heightCm: 100)
      ),
    ]
    for (text, expected) in cases {
      XCTAssertEqual(try Request.decode(Data(text.utf8)), expected)
    }
  }

  func testWaitDefaultsToTrue() throws {
    let request = try Request.decode(Data(#"{"v":1,"cmd":"moveBy","deltaCm":1}"#.utf8))
    XCTAssertEqual(request, .moveBy(deltaCm: 1, wait: true))
  }

  func testUnknownFieldsAreIgnored() throws {
    let text = #"{"v":1,"cmd":"stop","future":{"a":[1,2]},"wait":"nonsense"}"#
    XCTAssertEqual(try Request.decode(Data(text.utf8)), .stop)
  }

  func testUnknownCommandIsUnsupported() {
    XCTAssertThrowsError(try Request.decode(Data(#"{"v":1,"cmd":"dance"}"#.utf8))) {
      XCTAssertEqual($0 as? RequestError, .unsupportedCommand("dance"))
    }
  }

  func testUnknownMajorVersionIsUnsupportedVersion() {
    XCTAssertThrowsError(try Request.decode(Data(#"{"v":2,"cmd":"dance"}"#.utf8))) {
      XCTAssertEqual($0 as? RequestError, .unsupportedVersion(2))
    }
    XCTAssertThrowsError(try Request.decode(Data(#"{"cmd":"status"}"#.utf8))) {
      XCTAssertEqual($0 as? RequestError, .unsupportedVersion(nil))
    }
  }

  func testMalformedRequests() {
    for text in [
      "not json", "[1,2]", #"{"v":1}"#, #"{"v":1,"cmd":"move"}"#, #"{"v":1,"cmd":"moveBy"}"#,
      #"{"v":1,"cmd":"positions.rename","from":"a"}"#, #"{"v":1,"cmd":"positions.save"}"#,
    ] {
      XCTAssertThrowsError(try Request.decode(Data(text.utf8)), text) {
        guard case .malformed = $0 as? RequestError else {
          return XCTFail("\(text): \($0)")
        }
      }
    }
  }

  func testResponsesRoundTripAndMatchDocumentedShapes() throws {
    let responses: [Response] = [
      Response(ok: true, heightCm: 110.1),
      .success,
      .failure(.unknownPosition, "No position named 'Stand'"),
      Response(
        ok: true,
        status: StatusPayload(
          state: .connected, moving: false, heightCm: 92.4, minCm: 62, maxCm: 127)),
      Response(
        ok: true,
        status: StatusPayload(
          state: .disconnected, moving: false, heightCm: nil, minCm: 62, maxCm: 127)),
      Response(
        ok: true, positions: [PositionPayload(id: "6F1C", name: "Sit", slug: "sit", heightCm: 72.5)]
      ),
      Response(
        ok: true, position: PositionPayload(id: "6F1C", name: "Sit", slug: "sit", heightCm: 72.5)),
    ]
    for response in responses {
      let message = try ServerMessage.decode(response.encodedLine())
      XCTAssertEqual(message, .response(response))
    }

    let failure = try json(
      Response.failure(.unknownPosition, "No position named 'Stand'").encodedLine())
    XCTAssertEqual(failure["ok"] as? Bool, false)
    XCTAssertEqual((failure["error"] as? [String: Any])?["code"] as? String, "unknownPosition")
    let status = try json(
      Response(
        ok: true,
        status: StatusPayload(
          state: .connected, moving: false, heightCm: 92.4, minCm: 62, maxCm: 127)
      ).encodedLine())
    let payload = try XCTUnwrap(status["status"] as? [String: Any])
    XCTAssertEqual(payload["state"] as? String, "connected")
    XCTAssertEqual(payload["heightCm"] as? Double, 92.4)
    XCTAssertEqual(payload["minCm"] as? Double, 62)
    let unknownHeight = try json(
      Response(
        ok: true,
        status: StatusPayload(
          state: .disconnected, moving: false, heightCm: nil, minCm: 62, maxCm: 127)
      ).encodedLine())
    XCTAssertNil((unknownHeight["status"] as? [String: Any])?["heightCm"])
  }

  func testEventsRoundTripAndMatchDocumentedShapes() throws {
    let events: [Event] = [
      .height(heightCm: 97.3, speedCmS: 3.6, state: .moving),
      .height(heightCm: 92.4, speedCmS: -1.2, state: .connected),
      .state(.disconnected),
      .state(.failed, message: "Bluetooth error", notFoundHint: false),
      .state(.scanning, notFoundHint: true),
    ]
    for event in events {
      XCTAssertEqual(try ServerMessage.decode(event.encodedLine()), .event(event))
    }
    XCTAssertEqual(
      try Event.state(.disconnected).encodedLine(),
      Data(#"{"event":"state","notFoundHint":false,"state":"disconnected"}"#.utf8 + [10]))
    let height = try json(Event.height(heightCm: 97.3, speedCmS: 3.6, state: .moving).encodedLine())
    XCTAssertEqual(height["event"] as? String, "height")
    XCTAssertEqual(height["heightCm"] as? Double, 97.3)
    XCTAssertEqual(height["speedCmS"] as? Double, 3.6)
    XCTAssertEqual(height["state"] as? String, "moving")
  }

  func testStatusCarriesFailureMessageAndNotFoundHint() throws {
    let failed = Response(
      ok: true,
      status: StatusPayload(
        state: .failed, moving: false, heightCm: nil, minCm: 62, maxCm: 127,
        message: "Bluetooth error", notFoundHint: true))
    XCTAssertEqual(try ServerMessage.decode(failed.encodedLine()), .response(failed))
    let payload = try XCTUnwrap(json(failed.encodedLine())["status"] as? [String: Any])
    XCTAssertEqual(payload["state"] as? String, "failed")
    XCTAssertEqual(payload["message"] as? String, "Bluetooth error")
    XCTAssertEqual(payload["notFoundHint"] as? Bool, true)

    let older = #"{"ok":true,"status":{"state":"connected","moving":false,"minCm":62,"maxCm":127}}"#
    let message = try ServerMessage.decode(Data(older.utf8))
    guard case .response(let response) = message else { return XCTFail("\(message)") }
    XCTAssertEqual(response.status?.notFoundHint, false)
    XCTAssertNil(response.status?.message)
  }

  func testEveryWireStateRoundTrips() throws {
    for state in WireState.allCases {
      XCTAssertEqual(
        try ServerMessage.decode(Event.state(state).encodedLine()), .event(.state(state)))
    }
  }

  func testUnknownErrorCodeFallsBackToInternal() throws {
    let text = #"{"ok":false,"error":{"code":"somethingNew","message":"x"}}"#
    let message = try ServerMessage.decode(Data(text.utf8))
    XCTAssertEqual(message, .response(.failure(.internal, "x")))
  }

  func testErrorCodesMapToDocumentedExitCodes() {
    let expected: [ErrorCode: Int32] = [
      .internal: 1, .notConnected: 4, .outOfRange: 5, .unknownPosition: 6, .moveFailed: 7,
      .interrupted: 8, .invalidName: 9, .unsupportedVersion: 10, .unsupported: 10,
      .deskMoving: 12, .positionsReadOnly: 13,
    ]
    XCTAssertEqual(Set(expected.keys), Set(ErrorCode.allCases))
    for (code, status) in expected {
      XCTAssertEqual(code.exitStatus, status, "\(code)")
    }
    XCTAssertEqual(ExitStatus.usage, 2)
    XCTAssertEqual(ExitStatus.appUnavailable, 3)
    XCTAssertEqual(ExitStatus.connectionLost, 11)
    XCTAssertEqual(ExitStatus.sigint, 130)
  }

  func testLineFramerSplitsAndBuffers() throws {
    var framer = LineFramer()
    XCTAssertEqual(try framer.append(Data("abc".utf8)), [])
    XCTAssertEqual(try framer.append(Data("def\nxy".utf8)), [Data("abcdef".utf8)])
    XCTAssertEqual(
      try framer.append(Data("z\n\nlast\n".utf8)), [Data("xyz".utf8), Data(), Data("last".utf8)])
  }

  func testLineFramerAcceptsExactlyMaxLength() throws {
    var framer = LineFramer()
    let line = Data(repeating: 0x61, count: LineFramer.maxLineLength)
    XCTAssertEqual(try framer.append(line + Data([10])), [line])
  }

  func testLineFramerRejectsOverlongLines() {
    var framer = LineFramer()
    XCTAssertThrowsError(
      try framer.append(Data(repeating: 0x61, count: LineFramer.maxLineLength + 1))
    ) {
      XCTAssertEqual($0 as? LineFramer.Failure, .lineTooLong)
    }
    var terminated = LineFramer()
    let line = Data(repeating: 0x61, count: LineFramer.maxLineLength + 1) + Data([10])
    XCTAssertThrowsError(try terminated.append(line)) {
      XCTAssertEqual($0 as? LineFramer.Failure, .lineTooLong)
    }
  }

  func testSocketPathUsesSupportDirectoryOverride() {
    let environment = [SocketPath.supportDirectoryVariable: "/tmp/idasen-x"]
    XCTAssertEqual(SocketPath.socketPath(environment: environment), "/tmp/idasen-x/control.sock")
    XCTAssertEqual(SocketPath.supportDirectory(environment: environment).path, "/tmp/idasen-x")
  }

  func testDefaultSocketPathIsInApplicationSupport() {
    let path = SocketPath.socketPath(environment: [:])
    XCTAssertTrue(
      path.hasSuffix("/Library/Application Support/\(SocketPath.directoryName)/control.sock"))
  }

  func testSocketPathLengthLimit() throws {
    let base = "/tmp/" + String(repeating: "a", count: SocketPath.maxLength - 5)
    XCTAssertEqual(base.utf8.count, SocketPath.maxLength)
    XCTAssertNoThrow(try SocketPath.validate(base))
    XCTAssertThrowsError(try SocketPath.validate(base + "a")) {
      XCTAssertEqual($0 as? SocketPathError, .tooLong(length: 104))
    }
  }

  func testProbeReportsAbsentSocket() throws {
    let path = "/tmp/idasen-probe-\(UInt32.random(in: 0...UInt32.max))"
    XCTAssertEqual(try SocketPath.probe(path: path), .absent)
  }

  func testPositionPayloadWithoutSlugDecodesAsEmpty() throws {
    let line = Data(#"{"ok":true,"position":{"heightCm":72.5,"id":"6F1C","name":"Sit"}}"#.utf8)
    let message = try ServerMessage.decode(line)
    XCTAssertEqual(
      message,
      .response(
        Response(
          ok: true, position: PositionPayload(id: "6F1C", name: "Sit", slug: "", heightCm: 72.5))
      ))
  }
}
