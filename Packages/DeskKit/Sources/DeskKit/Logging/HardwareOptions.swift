import Foundation

extension HoldVariant {
  public var label: String {
    switch self {
    case .targetLimit: "A"
    case .commandPulses: "B"
    case .directionSentinel: "C"
    }
  }

  public init?(label: String) {
    switch label.trimmingCharacters(in: .whitespaces).uppercased() {
    case "A": self = .targetLimit
    case "B": self = .commandPulses
    case "C": self = .directionSentinel
    default: return nil
    }
  }
}

public struct HardwareOptions: Equatable, Sendable {
  public static let holdVariantKey = "holdVariant"
  public static let patchUserIDKey = "dpgPatchesUserID"

  public var holdVariant: HoldVariant
  public var patchesUserID: Bool

  public init(holdVariant: HoldVariant = .targetLimit, patchesUserID: Bool = false) {
    self.holdVariant = holdVariant
    self.patchesUserID = patchesUserID
  }

  public init(defaults: UserDefaults) {
    holdVariant =
      defaults.string(forKey: Self.holdVariantKey).flatMap(HoldVariant.init(label:)) ?? .targetLimit
    patchesUserID = defaults.bool(forKey: Self.patchUserIDKey)
  }
}
