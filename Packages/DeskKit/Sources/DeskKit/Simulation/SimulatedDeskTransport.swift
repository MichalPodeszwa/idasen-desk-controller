import Foundation

@MainActor
public final class SimulatedDeskTransport: DeskTransport {
  public struct Configuration: Sendable {
    public var baseMM = DeskHeight.defaultBaseMM
    public var initialRaw = 1000
    public var speedMMPerSecond = 38.0
    public var rampDuration = Duration.milliseconds(250)
    public var coastTimeout = Duration.seconds(1)
    public var pulseDuration = Duration.seconds(1)
    public var notificationInterval = Duration.milliseconds(100)
    public var finalNotificationOffsetRaw = -6
    public var finalNotificationSpeedRaw = 0
    public var respondsToBaseOffset = true
    public var userID: Data?
    public var deskName = "Desk 1234"
    public var deskRSSI = -55
    public var knowsDesk = true
    public var connectDelay = Duration.zero
    public var notFoundHintDelay = Duration.seconds(15)

    public init() {}
  }

  public struct Faults: Equatable, Sendable {
    public var doesNotStart = false
    public var pairingRequired: PairingReason?
    public var notFound = false
    public var notificationInterval: Duration?

    public init() {}
  }

  static let physicsStep = Duration.milliseconds(10)
  static let brakeFactor = 4.0

  public private(set) var connectionState = TransportConnectionState.disconnected
  public private(set) var discoveredDesks: [DiscoveredDesk] = []
  public private(set) var baseOffsetMM: Double?
  public private(set) var notFoundHint = false
  public var canSendWriteWithoutResponse = true
  public let events: AsyncStream<DeskTransportEvent>
  public var faults = Faults()
  public private(set) var configuration: Configuration
  public private(set) var isBlockedByCollision = false
  public private(set) var userID: Data?

  public let desk: DiscoveredDesk

  private let continuation: AsyncStream<DeskTransportEvent>.Continuation
  private let clock: any DeskClock
  private var knowsDesk: Bool
  private var connectTask: Task<Void, Never>?
  private var hintTask: Task<Void, Never>?
  private var notifyTask: Task<Void, Never>?

  private var position: Double
  private var velocity = 0.0
  private var mode = Mode.idle
  private var lastUpdate: Duration
  private var awake = false
  private var obstacle: Obstacle?

  private enum Mode {
    case idle
    case reference(target: Double, refreshedAt: Duration)
    case run(MoveDirection, until: Duration)
    case panel(MoveDirection, until: Duration)
    case braking(factor: Double)
  }

  private struct Obstacle {
    var raw: Double
    var blocks: MoveDirection?
  }

  public init(clock: any DeskClock = SystemDeskClock(), configuration: Configuration = .init()) {
    self.clock = clock
    self.configuration = configuration
    desk = DiscoveredDesk(id: UUID(), name: configuration.deskName, rssi: configuration.deskRSSI)
    knowsDesk = configuration.knowsDesk
    userID = configuration.userID
    position = Double(DeskHeight(clamping: configuration.initialRaw).raw)
    lastUpdate = clock.elapsed
    (events, continuation) = AsyncStream.makeStream(of: DeskTransportEvent.self)
  }

  public var heightRaw: Int {
    DeskHeight(clamping: Int(position.rounded())).raw
  }

  public var speedRaw: Int {
    Int(velocity.rounded())
  }

  public var isMoving: Bool {
    if case .idle = mode { return velocity != 0 }
    return true
  }

  public func readHeight() async throws -> HeightSample {
    guard connectionState == .connected else { throw DeskTransportError.notConnected }
    advance()
    return HeightSample(heightRaw: heightRaw, speedRaw: speedRaw)
  }

  public func write(_ data: Data, to characteristic: DeskCharacteristic, type: DeskWriteType)
    async throws
  {
    guard connectionState == .connected else { throw DeskTransportError.notConnected }
    advance()
    switch characteristic {
    case .control: receiveControl(data)
    case .referenceInput: receiveReferenceInput(data)
    case .dpg: receiveDPG(data)
    }
    startNotifying()
  }

  public func connect() {
    guard connectionState == .disconnected || isPairingRequired || connectionState == .scanning
    else { return }
    connectTask?.cancel()
    connectTask = Task { await runConnect() }
  }

  public func connect(to id: DiscoveredDesk.ID) {
    guard id == desk.id else { return }
    knowsDesk = true
    connect()
  }

  public func disconnect() {
    connectTask?.cancel()
    clearHint()
    setConnectionState(.disconnected)
  }

  public func forget() {
    knowsDesk = false
    disconnect()
    publishDesks([])
  }

  public func simulateLinkLoss() {
    guard connectionState == .connected else { return }
    disconnect()
  }

  public func injectCollision(atRaw raw: Int) {
    advance()
    obstacle = Obstacle(raw: Double(raw), blocks: nil)
  }

  public func clearCollision() {
    obstacle = nil
    isBlockedByCollision = false
  }

  public func pressPanel(_ direction: MoveDirection, for duration: Duration = .seconds(1)) {
    advance()
    guard !isBlockedByCollision else { return }
    mode = .panel(direction, until: lastUpdate + duration)
    startNotifying()
  }

  public func setHeight(raw: Int) {
    position = Double(DeskHeight(clamping: raw).raw)
    velocity = 0
    mode = .idle
    lastUpdate = clock.elapsed
  }

  public func dpgResponse(to frame: Data) -> Data? {
    let bytes = Array(frame)
    guard bytes.count >= DPG.headerLength, bytes[0] == DPG.prefix else { return nil }
    let isRead = bytes[2] == DPG.readFlag
    switch bytes[1] {
    case DPG.Command.baseOffset.rawValue where isRead && configuration.respondsToBaseOffset:
      let tenths = UInt16((configuration.baseMM * 10).rounded())
      return Data([DPG.validStatus, bytes[1], 0x00, UInt8(tenths & 0xFF), UInt8(tenths >> 8)])
    case DPG.Command.userID.rawValue:
      if !isRead {
        userID = Data(bytes.dropFirst(DPG.headerLength))
        return nil
      }
      guard let userID else { return nil }
      return Data([DPG.validStatus, bytes[1], 0x00]) + userID
    default:
      return nil
    }
  }

  private var isPairingRequired: Bool {
    if case .pairingRequired = connectionState { true } else { false }
  }

  private func runConnect() async {
    let hasDelay = configuration.connectDelay > .zero
    if !knowsDesk {
      setConnectionState(.scanning)
      publishDesks([desk])
      return
    }
    if faults.notFound {
      setConnectionState(.scanning)
      startHintTimer()
      return
    }
    setConnectionState(.scanning)
    publishDesks([desk])
    if hasDelay { try? await clock.sleep(for: configuration.connectDelay) }
    guard !Task.isCancelled else { return }
    setConnectionState(.connecting)
    if hasDelay { try? await clock.sleep(for: configuration.connectDelay) }
    guard !Task.isCancelled else { return }
    if let reason = faults.pairingRequired {
      setConnectionState(.pairingRequired(reason))
      return
    }
    baseOffsetMM = dpgResponse(to: DPG.readFrame(.baseOffset)).flatMap(DPG.parseBaseOffsetMM)
    continuation.yield(.baseOffset(baseOffsetMM))
    awake = false
    setConnectionState(.connected)
    advance()
    continuation.yield(.sample(HeightSample(heightRaw: heightRaw, speedRaw: speedRaw)))
    startNotifying()
  }

  private func startHintTimer() {
    hintTask?.cancel()
    hintTask = Task {
      try? await clock.sleep(for: configuration.notFoundHintDelay)
      guard !Task.isCancelled else { return }
      notFoundHint = true
      continuation.yield(.notFoundHint(true))
    }
  }

  private func clearHint() {
    hintTask?.cancel()
    hintTask = nil
    guard notFoundHint else { return }
    notFoundHint = false
    continuation.yield(.notFoundHint(false))
  }

  private func setConnectionState(_ state: TransportConnectionState) {
    guard state != connectionState else { return }
    if state != .scanning { clearHint() }
    connectionState = state
    continuation.yield(.connectionState(state))
  }

  private func publishDesks(_ desks: [DiscoveredDesk]) {
    guard desks != discoveredDesks else { return }
    discoveredDesks = desks
    continuation.yield(.discoveredDesks(desks))
  }

  private func receiveControl(_ data: Data) {
    switch data {
    case DeskCommand.wake.bytes:
      awake = true
    case DeskCommand.stop.bytes:
      receiveStop()
    case DeskCommand.up.bytes:
      beginRun(.up)
    case DeskCommand.down.bytes:
      beginRun(.down)
    default:
      break
    }
  }

  private func receiveReferenceInput(_ data: Data) {
    guard data.count == 2 else { return }
    switch data {
    case ReferenceInput.stop:
      receiveStop()
      return
    case ReferenceInput.directionUp:
      beginReference(target: Double(DeskHeight.range.upperBound))
    case ReferenceInput.directionDown:
      beginReference(target: Double(DeskHeight.range.lowerBound))
    default:
      let bytes = Array(data)
      let raw = Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
      guard let height = DeskHeight(validating: raw) else { return }
      beginReference(target: Double(height.raw))
    }
  }

  private func receiveDPG(_ data: Data) {
    _ = dpgResponse(to: data)
  }

  private func receiveStop() {
    isBlockedByCollision = false
    switch mode {
    case .idle, .panel:
      break
    default:
      mode = .braking(factor: Self.brakeFactor)
    }
  }

  private func beginReference(target: Double) {
    guard awake, !isBlockedByCollision, !faults.doesNotStart else { return }
    if case .panel = mode { return }
    mode = .reference(target: target, refreshedAt: lastUpdate)
  }

  private func beginRun(_ direction: MoveDirection) {
    guard !isBlockedByCollision, !faults.doesNotStart else { return }
    if case .panel = mode { return }
    mode = .run(direction, until: lastUpdate + configuration.pulseDuration)
  }

  private var maxSpeed: Double {
    configuration.speedMMPerSecond * 10
  }

  private var acceleration: Double {
    maxSpeed / Self.seconds(configuration.rampDuration)
  }

  private static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  private func advance() {
    let now = clock.elapsed
    while lastUpdate < now {
      if case .idle = mode, velocity == 0 {
        lastUpdate = now
        return
      }
      let step = min(Self.physicsStep, now - lastUpdate)
      lastUpdate += step
      integrate(Self.seconds(step))
    }
  }

  private func integrate(_ dt: Double) {
    let limit = Double(DeskHeight.range.upperBound)
    var braking = acceleration
    var desired = 0.0
    var snapTarget: Double?

    switch mode {
    case .idle:
      break
    case .reference(let target, let refreshedAt):
      if lastUpdate - refreshedAt > configuration.coastTimeout {
        mode = .braking(factor: 1)
        break
      }
      let distance = target - position
      desired =
        (distance < 0 ? -1 : 1) * min(maxSpeed, (2 * acceleration * abs(distance)).squareRoot())
      snapTarget = target
    case .run(let direction, let until), .panel(let direction, let until):
      if lastUpdate > until {
        mode = .braking(factor: 1)
        break
      }
      desired = direction == .up ? maxSpeed : -maxSpeed
    case .braking(let factor):
      braking = acceleration * factor
    }

    let delta = braking * dt
    if velocity < desired {
      velocity = min(velocity + delta, desired)
    } else if velocity > desired {
      velocity = max(velocity - delta, desired)
    }
    let next = position + velocity * dt

    if let snapTarget,
      (position - snapTarget) * (next - snapTarget) <= 0 || abs(next - snapTarget) < 0.5
    {
      position = snapTarget
      velocity = 0
      mode = .idle
      return
    }
    if let hit = collision(from: position, to: next) {
      position = hit
      velocity = 0
      mode = .idle
      isBlockedByCollision = true
      return
    }
    if next <= 0 || next >= limit {
      position = min(max(next, 0), limit)
      velocity = 0
      mode = .idle
      return
    }
    position = next
    if case .braking = mode, abs(velocity) < 1 {
      velocity = 0
      mode = .idle
    }
  }

  private func collision(from start: Double, to end: Double) -> Double? {
    guard var obstacle else { return nil }
    let direction: MoveDirection = end >= start ? .up : .down
    guard end != start else { return nil }
    let crossed =
      direction == .up
      ? start < obstacle.raw && obstacle.raw <= end : start > obstacle.raw && obstacle.raw >= end
    let blocked =
      obstacle.blocks == direction && (direction == .up ? end >= obstacle.raw : end <= obstacle.raw)
    guard crossed || blocked else { return nil }
    obstacle.blocks = direction
    self.obstacle = obstacle
    return obstacle.raw
  }

  private func startNotifying() {
    guard notifyTask == nil, isMoving else { return }
    notifyTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let interval = self.faults.notificationInterval ?? self.configuration.notificationInterval
        try? await self.clock.sleep(for: interval)
        guard !Task.isCancelled else { return }
        self.advance()
        if self.isMoving {
          self.notify(HeightSample(heightRaw: self.heightRaw, speedRaw: self.speedRaw))
          continue
        }
        self.notify(
          HeightSample(
            heightRaw: DeskHeight(
              clamping: self.heightRaw + self.configuration.finalNotificationOffsetRaw
            ).raw,
            speedRaw: self.configuration.finalNotificationSpeedRaw))
        self.notifyTask = nil
        return
      }
    }
  }

  private func notify(_ sample: HeightSample) {
    guard connectionState == .connected else { return }
    continuation.yield(.sample(sample))
  }
}
