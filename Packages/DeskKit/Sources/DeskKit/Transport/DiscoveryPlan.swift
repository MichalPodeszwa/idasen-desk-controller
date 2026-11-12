import Foundation

struct DiscoveryPlan {
  static let nameFallbackDelay = Duration.seconds(5)
  static let notFoundHintDelay = Duration.seconds(15)
  static let namePrefix = "Desk"

  enum ScanMode: Equatable {
    case service
    case namePrefix
  }

  enum Stage: Equatable {
    case idle
    case pendingConnect
    case scanning(ScanMode)
    case attached
  }

  enum Action: Equatable {
    case connect(UUID)
    case scan(ScanMode)
    case stopScan
    case scheduleNameFallback(Duration)
    case scheduleNotFoundHint(Duration)
    case cancelTimers
    case setHint(Bool)
  }

  private(set) var stage = Stage.idle

  var isSearching: Bool {
    switch stage {
    case .pendingConnect, .scanning: true
    case .idle, .attached: false
    }
  }

  static func isDeskName(_ name: String?) -> Bool {
    name?.hasPrefix(namePrefix) == true
  }

  mutating func start(
    remembered: UUID?, connectedAtSystemLevel: UUID?, rememberedKnownToSystem: Bool,
    hintDelay: Duration = DiscoveryPlan.notFoundHintDelay
  ) -> [Action] {
    if let connectedAtSystemLevel {
      return connect(connectedAtSystemLevel, hintDelay: hintDelay)
    }
    if let remembered, rememberedKnownToSystem {
      return connect(remembered, hintDelay: hintDelay)
    }
    stage = .scanning(.service)
    return [
      .scan(.service), .scheduleNameFallback(Self.nameFallbackDelay),
      .scheduleNotFoundHint(hintDelay),
    ]
  }

  mutating func connectPicked(
    _ id: UUID, hintDelay: Duration = DiscoveryPlan.notFoundHintDelay
  ) -> [Action] {
    let wasScanning = if case .scanning = stage { true } else { false }
    return (wasScanning ? [.stopScan] : []) + [.cancelTimers] + connect(id, hintDelay: hintDelay)
  }

  private mutating func connect(_ id: UUID, hintDelay: Duration) -> [Action] {
    stage = .pendingConnect
    return [.connect(id), .scheduleNotFoundHint(hintDelay)]
  }

  mutating func nameFallbackFired() -> [Action] {
    guard stage == .scanning(.service) else { return [] }
    stage = .scanning(.namePrefix)
    return [.scan(.namePrefix)]
  }

  mutating func notFoundHintFired() -> [Action] {
    isSearching ? [.setHint(true)] : []
  }

  mutating func attached() -> [Action] {
    let wasScanning = if case .scanning = stage { true } else { false }
    stage = .attached
    return (wasScanning ? [.stopScan] : []) + [.cancelTimers, .setHint(false)]
  }

  mutating func stop() -> [Action] {
    let wasScanning = if case .scanning = stage { true } else { false }
    stage = .idle
    return (wasScanning ? [.stopScan] : []) + [.cancelTimers, .setHint(false)]
  }
}

struct DiscoveredDeskList {
  static let rssiChangeThreshold = 4

  private var byID: [UUID: DiscoveredDesk] = [:]

  var desks: [DiscoveredDesk] {
    byID.values.sorted { lhs, rhs in
      if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  mutating func update(id: UUID, name: String, rssi: Int) -> Bool {
    if let existing = byID[id], existing.name == name,
      abs(existing.rssi - rssi) < Self.rssiChangeThreshold
    {
      return false
    }
    byID[id] = DiscoveredDesk(id: id, name: name, rssi: rssi)
    return true
  }

  mutating func removeAll() -> Bool {
    defer { byID = [:] }
    return !byID.isEmpty
  }
}
