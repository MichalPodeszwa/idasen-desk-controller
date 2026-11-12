import Foundation

@MainActor
public protocol DeskSettings: AnyObject {
  var rememberedPeripheral: UUID? { get set }
}

@MainActor
public final class UserDefaultsDeskSettings: DeskSettings {
  public static let rememberedPeripheralKey = "rememberedPeripheral"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var rememberedPeripheral: UUID? {
    get { defaults.string(forKey: Self.rememberedPeripheralKey).flatMap(UUID.init(uuidString:)) }
    set { defaults.set(newValue?.uuidString, forKey: Self.rememberedPeripheralKey) }
  }
}

@MainActor
public final class InMemoryDeskSettings: DeskSettings {
  public var rememberedPeripheral: UUID?

  public init(rememberedPeripheral: UUID? = nil) {
    self.rememberedPeripheral = rememberedPeripheral
  }
}
