import Foundation

public struct LineFramer: Sendable {
  public static let maxLineLength = 64 * 1024

  public enum Failure: Error, Equatable, Sendable {
    case lineTooLong
  }

  private var buffer = Data()

  public init() {}

  public mutating func append(_ data: Data) throws(Failure) -> [Data] {
    buffer.append(data)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<newline]
      guard line.count <= Self.maxLineLength else { throw .lineTooLong }
      lines.append(Data(line))
      buffer = Data(buffer[buffer.index(after: newline)...])
    }
    guard buffer.count <= Self.maxLineLength else { throw .lineTooLong }
    return lines
  }
}
