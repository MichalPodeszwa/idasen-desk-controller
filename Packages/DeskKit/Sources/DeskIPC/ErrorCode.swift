public enum ErrorCode: String, Codable, CaseIterable, Sendable {
  case `internal`
  case notConnected
  case outOfRange
  case unknownPosition
  case moveFailed
  case interrupted
  case invalidName
  case unsupportedVersion
  case unsupported
  case deskMoving
  case positionsReadOnly

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: raw) ?? .internal
  }

  public var exitStatus: Int32 {
    switch self {
    case .internal: ExitStatus.failure
    case .notConnected: 4
    case .outOfRange: 5
    case .unknownPosition: 6
    case .moveFailed: 7
    case .interrupted: 8
    case .invalidName: 9
    case .unsupportedVersion, .unsupported: ExitStatus.versionMismatch
    case .deskMoving: 12
    case .positionsReadOnly: 13
    }
  }
}

public enum ExitStatus {
  public static let ok: Int32 = 0
  public static let failure: Int32 = 1
  public static let usage: Int32 = 2
  public static let appUnavailable: Int32 = 3
  public static let versionMismatch: Int32 = 10
  public static let connectionLost: Int32 = 11
  public static let sigint: Int32 = 130
}

public struct WireError: Codable, Equatable, Sendable {
  public var code: ErrorCode
  public var message: String

  public init(code: ErrorCode, message: String) {
    self.code = code
    self.message = message
  }
}
