import Foundation

public enum DPG {
  public enum Command: UInt8, Sendable {
    case capabilities = 0x80
    case baseOffset = 0x81
    case userID = 0x86
  }

  static let prefix: UInt8 = 0x7F
  static let readFlag: UInt8 = 0x00
  static let writeFlag: UInt8 = 0x80
  static let validStatus: UInt8 = 0x01

  public static func readFrame(_ command: Command) -> Data {
    Data([prefix, command.rawValue, readFlag])
  }

  public static func writeFrame(_ command: Command, data: Data) -> Data {
    Data([prefix, command.rawValue, writeFlag]) + data
  }

  static let headerLength = 3

  public static func payload(of response: Data) -> Data? {
    let bytes = Array(response)
    guard bytes.count >= headerLength, bytes[0] == validStatus else { return nil }
    return Data(bytes[headerLength...])
  }

  public static func parseBaseOffsetMM(_ response: Data) -> Double? {
    guard let payload = payload(of: response), payload.count >= 2 else { return nil }
    let bytes = Array(payload)
    let tenthsMM = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    return Double(tenthsMM) / 10
  }

  public static func userIDPatchFrame(response: Data) -> Data? {
    guard let payload = payload(of: response) else { return nil }
    var bytes = Array(payload)
    guard let first = bytes.first, first != validStatus else { return nil }
    bytes[0] = validStatus
    return writeFrame(.userID, data: Data(bytes))
  }
}
