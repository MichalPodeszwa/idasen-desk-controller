public struct DeskHeight: Hashable, Comparable, Sendable {
  public static let range = 0...6500
  public static let defaultBaseMM = 620.0

  public let raw: Int

  public init(clamping raw: Int) {
    self.raw = min(max(raw, Self.range.lowerBound), Self.range.upperBound)
  }

  public init?(validating raw: Int) {
    guard Self.range.contains(raw) else { return nil }
    self.raw = raw
  }

  public init?(cm: Double, baseMM: Double, calibrationMM: Double = 0) {
    guard let raw = Self.rawUnits(cm: cm, baseMM: baseMM, calibrationMM: calibrationMM) else {
      return nil
    }
    self.init(validating: raw)
  }

  public init?(clampingCm cm: Double, baseMM: Double, calibrationMM: Double = 0) {
    guard let raw = Self.rawUnits(cm: cm, baseMM: baseMM, calibrationMM: calibrationMM) else {
      return nil
    }
    self.init(clamping: raw)
  }

  public static func rawUnits(cm: Double, baseMM: Double, calibrationMM: Double = 0) -> Int? {
    let raw = ((cm * 10) - baseMM - calibrationMM) * 10
    guard raw.isFinite else { return nil }
    return Int(min(max(raw.rounded(.toNearestOrAwayFromZero), -1_000_000), 1_000_000))
  }

  public func cm(baseMM: Double, calibrationMM: Double = 0) -> Double {
    (Double(raw) / 10 + baseMM + calibrationMM) / 10
  }

  public static func < (lhs: DeskHeight, rhs: DeskHeight) -> Bool {
    lhs.raw < rhs.raw
  }
}
