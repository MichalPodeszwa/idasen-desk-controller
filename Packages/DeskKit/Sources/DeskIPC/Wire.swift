import Foundation

public enum WireState: String, Codable, CaseIterable, Sendable {
  case bluetoothOff
  case unauthorized
  case disconnected
  case scanning
  case connecting
  case pairingRequired
  case connected
  case moving
  case failed
}

public enum MoveTarget: Equatable, Sendable {
  case heightCm(Double)
  case position(String)
}

public enum Request: Equatable, Sendable {
  case status
  case move(MoveTarget, wait: Bool)
  case moveBy(deltaCm: Double, wait: Bool)
  case stop
  case positionsList
  case positionsSave(name: String, heightCm: Double?)
  case positionsRemove(name: String)
  case positionsRename(from: String, to: String)
  case connect
  case watch
}

public enum RequestError: Error, Equatable, Sendable {
  case malformed(String)
  case unsupportedVersion(Int?)
  case unsupportedCommand(String)
}

extension Request {
  public var commandName: String {
    switch self {
    case .status: "status"
    case .move: "move"
    case .moveBy: "moveBy"
    case .stop: "stop"
    case .positionsList: "positions.list"
    case .positionsSave: "positions.save"
    case .positionsRemove: "positions.remove"
    case .positionsRename: "positions.rename"
    case .connect: "connect"
    case .watch: "watch"
    }
  }

  public func encodedLine() throws -> Data {
    try WireCoding.line(Wire(self))
  }

  public static func decode(_ line: Data) throws(RequestError) -> Request {
    let wire: Wire
    do {
      wire = try JSONDecoder().decode(Wire.self, from: line)
    } catch {
      throw .malformed("Request is not valid JSON")
    }
    guard wire.v == DeskIPC.protocolVersion else { throw .unsupportedVersion(wire.v) }
    guard let cmd = wire.cmd else { throw .malformed("Missing cmd") }
    switch cmd {
    case "status": return .status
    case "stop": return .stop
    case "connect": return .connect
    case "watch": return .watch
    case "positions.list": return .positionsList
    case "move":
      if let heightCm = wire.target?.heightCm {
        return .move(.heightCm(heightCm), wait: wire.wait ?? true)
      }
      if let position = wire.target?.position {
        return .move(.position(position), wait: wire.wait ?? true)
      }
      throw .malformed("move needs a target")
    case "moveBy":
      guard let deltaCm = wire.deltaCm else { throw .malformed("moveBy needs deltaCm") }
      return .moveBy(deltaCm: deltaCm, wait: wire.wait ?? true)
    case "positions.save":
      guard let name = wire.name else { throw .malformed("positions.save needs a name") }
      return .positionsSave(name: name, heightCm: wire.heightCm)
    case "positions.remove":
      guard let name = wire.name else { throw .malformed("positions.remove needs a name") }
      return .positionsRemove(name: name)
    case "positions.rename":
      guard let from = wire.from, let to = wire.to else {
        throw .malformed("positions.rename needs from and to")
      }
      return .positionsRename(from: from, to: to)
    default:
      throw .unsupportedCommand(cmd)
    }
  }
}

private struct Wire: Codable {
  struct Target: Codable {
    var heightCm: Double?
    var position: String?
  }

  var v: Int?
  var cmd: String?
  var target: Target?
  var wait: Bool?
  var deltaCm: Double?
  var name: String?
  var heightCm: Double?
  var from: String?
  var to: String?

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    v = try? container.decodeIfPresent(Int.self, forKey: .v)
    cmd = try? container.decodeIfPresent(String.self, forKey: .cmd)
    target = try? container.decodeIfPresent(Target.self, forKey: .target)
    wait = try? container.decodeIfPresent(Bool.self, forKey: .wait)
    deltaCm = try? container.decodeIfPresent(Double.self, forKey: .deltaCm)
    name = try? container.decodeIfPresent(String.self, forKey: .name)
    heightCm = try? container.decodeIfPresent(Double.self, forKey: .heightCm)
    from = try? container.decodeIfPresent(String.self, forKey: .from)
    to = try? container.decodeIfPresent(String.self, forKey: .to)
  }

  init(_ request: Request) {
    v = DeskIPC.protocolVersion
    cmd = request.commandName
    switch request {
    case .move(let target, let wait):
      switch target {
      case .heightCm(let heightCm): self.target = Target(heightCm: heightCm)
      case .position(let position): self.target = Target(position: position)
      }
      self.wait = wait
    case .moveBy(let deltaCm, let wait):
      self.deltaCm = deltaCm
      self.wait = wait
    case .positionsSave(let name, let heightCm):
      self.name = name
      self.heightCm = heightCm
    case .positionsRemove(let name):
      self.name = name
    case .positionsRename(let from, let to):
      self.from = from
      self.to = to
    case .status, .stop, .positionsList, .connect, .watch:
      break
    }
  }
}

public struct StatusPayload: Codable, Equatable, Sendable {
  public var state: WireState
  public var moving: Bool
  public var heightCm: Double?
  public var minCm: Double
  public var maxCm: Double
  public var message: String?
  public var notFoundHint: Bool

  public init(
    state: WireState, moving: Bool, heightCm: Double?, minCm: Double, maxCm: Double,
    message: String? = nil, notFoundHint: Bool = false
  ) {
    self.state = state
    self.moving = moving
    self.heightCm = heightCm
    self.minCm = minCm
    self.maxCm = maxCm
    self.message = message
    self.notFoundHint = notFoundHint
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    state = try container.decode(WireState.self, forKey: .state)
    moving = try container.decode(Bool.self, forKey: .moving)
    heightCm = try container.decodeIfPresent(Double.self, forKey: .heightCm)
    minCm = try container.decode(Double.self, forKey: .minCm)
    maxCm = try container.decode(Double.self, forKey: .maxCm)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    notFoundHint = try container.decodeIfPresent(Bool.self, forKey: .notFoundHint) ?? false
  }
}

public struct PositionPayload: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var slug: String
  public var heightCm: Double

  public init(id: String, name: String, slug: String, heightCm: Double) {
    self.id = id
    self.name = name
    self.slug = slug
    self.heightCm = heightCm
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
    heightCm = try container.decode(Double.self, forKey: .heightCm)
  }
}

public struct Response: Codable, Equatable, Sendable {
  public var ok: Bool
  public var heightCm: Double?
  public var status: StatusPayload?
  public var positions: [PositionPayload]?
  public var position: PositionPayload?
  public var error: WireError?

  public init(
    ok: Bool, heightCm: Double? = nil, status: StatusPayload? = nil,
    positions: [PositionPayload]? = nil, position: PositionPayload? = nil,
    error: WireError? = nil
  ) {
    self.ok = ok
    self.heightCm = heightCm
    self.status = status
    self.positions = positions
    self.position = position
    self.error = error
  }

  public static var success: Response {
    Response(ok: true)
  }

  public static func failure(_ code: ErrorCode, _ message: String) -> Response {
    Response(ok: false, error: WireError(code: code, message: message))
  }

  public func encodedLine() throws -> Data {
    try WireCoding.line(self)
  }
}

public enum Event: Codable, Equatable, Sendable {
  case height(heightCm: Double, speedCmS: Double, state: WireState)
  case state(WireState, message: String? = nil, notFoundHint: Bool = false)

  private enum CodingKeys: String, CodingKey {
    case event, heightCm, speedCmS, state, message, notFoundHint
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .event) {
    case "height":
      self = .height(
        heightCm: try container.decode(Double.self, forKey: .heightCm),
        speedCmS: try container.decode(Double.self, forKey: .speedCmS),
        state: try container.decode(WireState.self, forKey: .state))
    case "state":
      self = .state(
        try container.decode(WireState.self, forKey: .state),
        message: try container.decodeIfPresent(String.self, forKey: .message),
        notFoundHint: try container.decodeIfPresent(Bool.self, forKey: .notFoundHint) ?? false)
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .event, in: container, debugDescription: "Unknown event \(other)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .height(let heightCm, let speedCmS, let state):
      try container.encode("height", forKey: .event)
      try container.encode(heightCm, forKey: .heightCm)
      try container.encode(speedCmS, forKey: .speedCmS)
      try container.encode(state, forKey: .state)
    case .state(let state, let message, let notFoundHint):
      try container.encode("state", forKey: .event)
      try container.encode(state, forKey: .state)
      try container.encodeIfPresent(message, forKey: .message)
      try container.encode(notFoundHint, forKey: .notFoundHint)
    }
  }

  public func encodedLine() throws -> Data {
    try WireCoding.line(self)
  }
}

public enum ServerMessage: Equatable, Sendable {
  case response(Response)
  case event(Event)

  public static func decode(_ line: Data) throws -> ServerMessage {
    struct Header: Decodable {
      var event: String?
    }
    let decoder = JSONDecoder()
    if try decoder.decode(Header.self, from: line).event != nil {
      return .event(try decoder.decode(Event.self, from: line))
    }
    return .response(try decoder.decode(Response.self, from: line))
  }
}

enum WireCoding {
  static func line(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data([0x0A])
  }
}
