import Foundation

public enum HeightSampleError: Error, Equatable, Sendable {
  case invalidLength(Int)
}

public struct HeightSample: Equatable, Sendable {
  public static let length = 4

  public let heightRaw: Int
  public let speedRaw: Int

  public init(heightRaw: Int, speedRaw: Int) {
    self.heightRaw = heightRaw
    self.speedRaw = speedRaw
  }

  public init(decoding data: Data) throws {
    guard data.count == Self.length else {
      throw HeightSampleError.invalidLength(data.count)
    }
    let bytes = Array(data)
    heightRaw = Int(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
    speedRaw = Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8))
  }

  public var height: DeskHeight {
    DeskHeight(clamping: heightRaw)
  }

  public var speedMMPerSecond: Double {
    Double(speedRaw) / 10
  }

  public var isStationary: Bool {
    speedRaw == 0
  }
}
