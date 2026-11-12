import Foundation

public enum DeskCommand: Sendable {
  case up
  case down
  case stop
  case wake

  public var bytes: Data {
    switch self {
    case .up: Data([0x47, 0x00])
    case .down: Data([0x46, 0x00])
    case .stop: Data([0xFF, 0x00])
    case .wake: Data([0xFE, 0x00])
    }
  }
}

public enum ReferenceInput {
  public static let stop = Data([0x01, 0x80])
  public static let directionUp = Data([0x00, 0x80])
  public static let directionDown = Data([0xFF, 0x7F])

  public static func target(_ height: DeskHeight) -> Data {
    let value = UInt16(bitPattern: Int16(height.raw))
    return Data([UInt8(value & 0xFF), UInt8(value >> 8)])
  }
}
