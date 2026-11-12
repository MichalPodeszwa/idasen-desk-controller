import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
  private enum Key {
    static let calibrationMM = "calibrationMM"
    static let showsIcon = "menuBarShowsIcon"
    static let showsUnit = "menuBarShowsUnit"
  }

  var calibrationMM: Double {
    didSet { defaults?.set(calibrationMM, forKey: Key.calibrationMM) }
  }

  var showsIcon: Bool {
    didSet { defaults?.set(showsIcon, forKey: Key.showsIcon) }
  }

  var showsUnit: Bool {
    didSet { defaults?.set(showsUnit, forKey: Key.showsUnit) }
  }

  @ObservationIgnored private let defaults: UserDefaults?

  init(defaults: UserDefaults?) {
    self.defaults = defaults
    calibrationMM = defaults?.double(forKey: Key.calibrationMM) ?? 0
    showsIcon = defaults?.object(forKey: Key.showsIcon) as? Bool ?? true
    showsUnit = defaults?.object(forKey: Key.showsUnit) as? Bool ?? false
  }
}
