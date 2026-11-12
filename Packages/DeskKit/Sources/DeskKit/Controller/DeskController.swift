import Foundation
import Observation

private let log = DeskLog.controller

@MainActor
@Observable
public final class DeskController {
  public typealias ActivityHook = @MainActor (_ reason: String) -> @MainActor () -> Void

  public static let processInfoActivity: ActivityHook = { reason in
    let token = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason)
    return { ProcessInfo.processInfo.endActivity(token) }
  }

  static let tickInterval = Duration.milliseconds(100)
  static let settleDelay = Duration.milliseconds(500)
  static let didNotStartLimit = Duration.milliseconds(1500)
  static let moveTimeout = Duration.seconds(30)
  static let holdLimit = Duration.seconds(20)
  static let stopVerifyDelay = Duration.milliseconds(300)
  static let externalIdleTimeout = Duration.seconds(1)
  static let externalSuppression = Duration.milliseconds(1200)
  static let readTimeout = Duration.seconds(1)
  static let pulseEveryTicks = 3
  static let skipThreshold = 20
  static let arrivalTolerance = 50
  static let startThreshold = 10
  static let watchBufferSize = 64

  public private(set) var state: DeskState
  public private(set) var heightRaw: Int?
  public private(set) var speedRaw = 0
  public private(set) var discoveredDesks: [DiscoveredDesk]
  public private(set) var baseOffsetMM: Double?
  public private(set) var notFoundHint: Bool

  public let positions: PositionStore
  private let transport: any DeskTransport
  private let clock: any DeskClock
  private let beginActivity: ActivityHook

  @ObservationIgnored private var connection: TransportConnectionState
  @ObservationIgnored private var activity: DeskActivity = .idle
  @ObservationIgnored private var active: ActiveMove?
  @ObservationIgnored private(set) var generation: UInt64 = 0
  @ObservationIgnored private var lastMoveID: UInt64 = 0
  @ObservationIgnored private var stopInFlight: Task<Void, Never>?
  @ObservationIgnored private var writeTail: Task<Result<Bool, any Error>, Never>?
  @ObservationIgnored private var pendingTeardowns = 0
  @ObservationIgnored private var externalIdleTask: Task<Void, Never>?
  @ObservationIgnored private var externalSuppressedUntil: Duration?
  @ObservationIgnored private var watchers: [UUID: AsyncStream<DeskEvent>.Continuation] = [:]

  public init(
    transport: any DeskTransport,
    positions: PositionStore,
    clock: any DeskClock = SystemDeskClock(),
    beginActivity: @escaping ActivityHook = DeskController.processInfoActivity
  ) {
    self.transport = transport
    self.positions = positions
    self.clock = clock
    self.beginActivity = beginActivity
    connection = transport.connectionState
    state = Self.state(for: transport.connectionState, activity: .idle)
    discoveredDesks = transport.discoveredDesks
    baseOffsetMM = transport.baseOffsetMM
    notFoundHint = transport.notFoundHint
    let events = transport.events
    Task { [weak self] in
      for await event in events {
        guard let self else { return }
        self.handle(event)
      }
    }
  }

  public var baseMM: Double {
    baseOffsetMM ?? DeskHeight.defaultBaseMM
  }

  public var currentMoveID: MoveID? {
    switch state {
    case .connected(.moving(.toTarget(_, let id))), .connected(.moving(.relative(_, let id))),
      .connected(.moving(.hold(_, let id))):
      id
    default: nil
    }
  }

  public func watch() -> AsyncStream<DeskEvent> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: DeskEvent.self, bufferingPolicy: .bufferingNewest(Self.watchBufferSize))
    let id = UUID()
    watchers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.watchers[id] = nil }
    }
    return stream
  }

  public func connect() {
    log.notice("command: connect()")
    transport.connect()
  }

  public func connect(to desk: DiscoveredDesk.ID) {
    log.notice("command: connect(to: \(desk.uuidString, privacy: .public))")
    transport.connect(to: desk)
  }

  public func disconnect() async {
    log.notice("command: disconnect()")
    await endActiveMove(with: .failed(.interrupted))
    transport.disconnect()
  }

  public func forgetDesk() async {
    log.notice("command: forgetDesk()")
    await endActiveMove(with: .failed(.interrupted))
    transport.forget()
  }

  public func prepareForSleep() async {
    log.notice("command: prepareForSleep()")
    await endActiveMove(with: .failed(.notConnected))
  }

  public func handleWake() {
    log.notice("command: handleWake()")
    transport.connect()
  }

  public func startMove(toRaw raw: Int) throws(DeskControllerError) -> MoveTicket {
    try requireConnected()
    guard let target = DeskHeight(validating: raw) else { throw .outOfRange }
    return begin(.target(target.raw))
  }

  public func move(toRaw raw: Int) async throws(DeskControllerError) -> Int {
    try await wait(for: startMove(toRaw: raw))
  }

  public func startMove(byRaw delta: Int) throws(DeskControllerError) -> MoveTicket {
    try requireConnected()
    switch active?.mode {
    case .target(let target):
      return begin(.target(DeskHeight(clamping: target + delta).raw))
    case .relative(let pending):
      return begin(.relative(pending + delta))
    case .hold, nil:
      guard let heightRaw else { return begin(.relative(delta)) }
      return begin(.target(DeskHeight(clamping: heightRaw + delta).raw))
    }
  }

  public func move(byRaw delta: Int) async throws(DeskControllerError) -> Int {
    try await wait(for: startMove(byRaw: delta))
  }

  public func startMove(toPositionNamed name: String) throws(DeskControllerError) -> MoveTicket {
    guard let position = positions.position(matching: name) else {
      throw .positions(.unknownPosition)
    }
    return try startMove(toRaw: position.height.raw)
  }

  public func move(toPositionNamed name: String) async throws(DeskControllerError) -> Int {
    try await wait(for: startMove(toPositionNamed: name))
  }

  public func startMove(toPositionID id: UUID) throws(DeskControllerError) -> MoveTicket {
    guard let position = positions.position(id: id) else { throw .positions(.unknownPosition) }
    return try startMove(toRaw: position.height.raw)
  }

  public func beginHold(
    _ direction: MoveDirection, input: any HoldInputSource, variant: HoldVariant = .targetLimit
  ) throws(DeskControllerError) -> MoveTicket {
    try requireConnected()
    return begin(.hold(direction, input, variant))
  }

  public func endHold() async {
    guard let active, case .hold = active.mode else { return }
    log.notice("command: endHold() for move #\(active.ticket.id.rawValue)")
    finish(active, .released)
    await stopInFlight?.value
  }

  public func stop() async {
    log.notice(
      "command: stop() activeMove=\(self.active.map { "#\($0.ticket.id.rawValue)" } ?? "none", privacy: .public) connected=\(self.connection == .connected)"
    )
    if let active {
      finish(active, .failed(.interrupted), alwaysStop: true)
    } else if connection == .connected {
      let previous = stopInFlight
      pendingTeardowns += 1
      stopInFlight = Task {
        await previous?.value
        await self.sendStopSequence(verify: false)
        self.pendingTeardowns -= 1
      }
    }
    await stopInFlight?.value
  }

  public func cancel(moveID: MoveID) async {
    guard let active, active.ticket.id == moveID else { return }
    log.notice("command: cancel(moveID: #\(moveID.rawValue))")
    finish(active, .failed(.interrupted))
    await stopInFlight?.value
  }

  public func settledHeight() throws(DeskControllerError) -> DeskHeight {
    try requireConnected()
    guard active == nil, pendingTeardowns == 0, activity == .idle else { throw .deskMoving }
    guard let heightRaw else { throw .notConnected }
    return DeskHeight(clamping: heightRaw)
  }

  @discardableResult
  public func savePosition(named name: String, raw: Int? = nil) throws(DeskControllerError)
    -> Position
  {
    let height: DeskHeight
    if let raw {
      guard let valid = DeskHeight(validating: raw) else { throw .outOfRange }
      height = valid
    } else {
      height = try settledHeight()
    }
    do throws(PositionError) {
      if let existing = positions.position(named: name) {
        try positions.updateHeight(id: existing.id, to: height)
        return positions.position(id: existing.id) ?? existing
      }
      return try positions.add(name: name, height: height)
    } catch {
      throw .positions(error)
    }
  }

  private func requireConnected() throws(DeskControllerError) {
    guard connection == .connected else { throw .notConnected }
  }

  private func wait(for ticket: MoveTicket) async throws(DeskControllerError) -> Int {
    let id = ticket.id
    let result = await withTaskCancellationHandler {
      await ticket.result()
    } onCancel: {
      Task { @MainActor [weak self] in await self?.cancel(moveID: id) }
    }
    return try result.get()
  }

  private func endActiveMove(with outcome: MoveOutcome) async {
    guard let active else { return }
    finish(active, outcome)
    await stopInFlight?.value
  }

  private func handle(_ event: DeskTransportEvent) {
    switch event {
    case .connectionState(let newState):
      updateConnection(newState)
    case .sample(let sample):
      receiveNotification(sample)
    case .discoveredDesks(let desks):
      discoveredDesks = desks
    case .baseOffset(let offset):
      baseOffsetMM = offset
    case .notFoundHint(let hint):
      guard hint != notFoundHint else { return }
      notFoundHint = hint
      broadcast(.notFoundHint(hint))
    }
  }

  private func updateConnection(_ newState: TransportConnectionState) {
    log.notice(
      "transport state -> \(String(describing: newState), privacy: .public) activeMove=\(self.active.map { "#\($0.ticket.id.rawValue)" } ?? "none", privacy: .public)"
    )
    connection = newState
    if newState != .connected {
      externalIdleTask?.cancel()
      if let active {
        finish(active, .failed(.notConnected))
      }
      activity = .idle
      heightRaw = nil
      speedRaw = 0
    }
    refreshState()
  }

  private var isExternalMoving: Bool {
    if case .moving(.external) = activity { return true }
    return false
  }

  private func receiveNotification(_ sample: HeightSample) {
    publish(sample)
    guard active == nil, pendingTeardowns == 0, connection == .connected else { return }
    if let externalSuppressedUntil, clock.elapsed < externalSuppressedUntil {
      log.debug(
        "notification ignored for external detection (post-move suppression): \(DeskLog.describe(sample, baseMM: self.baseMM), privacy: .public)"
      )
      return
    }
    externalIdleTask?.cancel()
    if sample.isStationary {
      if isExternalMoving {
        log.notice(
          "external movement ended (zero speed): \(DeskLog.describe(sample, baseMM: self.baseMM), privacy: .public)"
        )
      }
      setActivity(.idle)
      return
    }
    if !isExternalMoving {
      log.notice(
        "external movement detected (panel?): \(DeskLog.describe(sample, baseMM: self.baseMM), privacy: .public)"
      )
    }
    setActivity(.moving(.external(sample.speedRaw > 0 ? .up : .down)))
    externalIdleTask = Task { [weak self] in
      guard let self else { return }
      try? await self.clock.sleep(for: Self.externalIdleTimeout)
      guard !Task.isCancelled, case .moving(.external) = self.activity else { return }
      log.notice("external movement ended (no notifications for 1 s)")
      self.setActivity(.idle)
    }
  }

  private func publish(_ sample: HeightSample) {
    heightRaw = sample.heightRaw
    speedRaw = sample.speedRaw
    broadcast(.sample(sample))
  }

  private func setActivity(_ newActivity: DeskActivity) {
    activity = newActivity
    refreshState()
  }

  private func refreshState() {
    let newState = Self.state(for: connection, activity: activity)
    guard newState != state else { return }
    log.notice(
      "state \(self.state.logDescription, privacy: .public) -> \(newState.logDescription, privacy: .public)"
    )
    state = newState
    broadcast(.state(newState))
  }

  private func broadcast(_ event: DeskEvent) {
    for watcher in watchers.values {
      watcher.yield(event)
    }
  }

  private static func state(
    for connection: TransportConnectionState, activity: DeskActivity
  ) -> DeskState {
    switch connection {
    case .poweredOff: .bluetoothOff
    case .unauthorized: .unauthorized
    case .disconnected: .disconnected
    case .scanning: .scanning
    case .connecting: .connecting
    case .pairingRequired(let reason): .pairingRequired(reason)
    case .failed(let message): .failed(message)
    case .connected: .connected(activity)
    }
  }

  private func begin(_ mode: ActiveMove.Mode) -> MoveTicket {
    if let active {
      log.notice("new command interrupts move #\(active.ticket.id.rawValue)")
      finish(active, .failed(.interrupted))
    }
    externalIdleTask?.cancel()
    generation &+= 1
    lastMoveID &+= 1
    let ticket = MoveTicket(id: MoveID(rawValue: lastMoveID))
    let move = ActiveMove(
      ticket: ticket, generation: generation, mode: mode,
      endActivity: beginActivity("Moving the desk"))
    active = move
    log.notice(
      "move #\(ticket.id.rawValue) begin: \(mode.logDescription, privacy: .public) generation=\(move.generation) heightKnown=\(self.heightRaw.map { String($0) } ?? "no", privacy: .public)"
    )
    switch mode {
    case .target(let raw): setActivity(.moving(.toTarget(raw: raw, id: ticket.id)))
    case .relative(let delta): setActivity(.moving(.relative(deltaRaw: delta, id: ticket.id)))
    case .hold(let direction, _, _): setActivity(.moving(.hold(direction, id: ticket.id)))
    }
    let prior = stopInFlight
    move.loopTask = Task {
      await prior?.value
      let outcome = await self.run(move)
      self.finish(move, outcome ?? .failed(.interrupted))
    }
    return ticket
  }

  private func finish(_ move: ActiveMove, _ outcome: MoveOutcome, alwaysStop: Bool = false) {
    guard active === move else { return }
    active = nil
    generation &+= 1
    move.loopTask?.cancel()
    setActivity(.idle)
    pendingTeardowns += 1
    let previous = stopInFlight
    let sendsStop = move.hasWritten || alwaysStop
    log.notice(
      "move #\(move.ticket.id.rawValue) end: \(outcome.logDescription, privacy: .public) isHold=\(move.mode.isHold) hasWritten=\(move.hasWritten) sendsStop=\(sendsStop)"
    )
    stopInFlight = Task {
      await previous?.value
      let result: Result<Int, DeskControllerError>
      switch outcome {
      case .arrived(let raw):
        result = .success(raw)
      case .released:
        if sendsStop { await self.sendStopSequence(verify: true) }
        result = self.heightRaw.map { .success($0) } ?? .failure(.notConnected)
      case .failed(let error):
        if sendsStop { await self.sendStopSequence(verify: true) }
        result = .failure(error)
      }
      if move.hasWritten {
        self.externalSuppressedUntil = self.clock.elapsed + Self.externalSuppression
      }
      self.pendingTeardowns -= 1
      move.ticket.resolve(result)
      move.endActivity()
    }
  }

  private func run(_ move: ActiveMove) async -> MoveOutcome? {
    do {
      return try await drive(move)
    } catch is Superseded {
      return nil
    } catch is CancellationError {
      return nil
    } catch {
      log.error(
        "move #\(move.ticket.id.rawValue) aborted by error: \(String(describing: error), privacy: .public) transportState=\(String(describing: self.transport.connectionState), privacy: .public)"
      )
      if error as? DeskTransportError == .notConnected || transport.connectionState != .connected {
        return .failed(.notConnected)
      }
      return .failed(.moveFailed(.transport(String(describing: error))))
    }
  }

  private func drive(_ move: ActiveMove) async throws -> MoveOutcome {
    try checkCurrent(move)
    let id = move.ticket.id.rawValue
    let start = try await read(for: move)
    log.notice(
      "move #\(id) initial read: \(DeskLog.describe(start, baseMM: self.baseMM), privacy: .public)")
    let target: Int
    switch move.mode {
    case .target(let raw):
      target = raw
    case .relative(let delta):
      target = DeskHeight(clamping: start.heightRaw + delta).raw
      move.mode = .target(target)
      setActivity(.moving(.toTarget(raw: target, id: move.ticket.id)))
    case .hold(.up, _, _):
      target = DeskHeight.range.upperBound
    case .hold(.down, _, _):
      target = DeskHeight.range.lowerBound
    }
    if abs(start.heightRaw - target) < Self.skipThreshold {
      log.notice(
        "move #\(id) skipped: start \(start.heightRaw) is within \(Self.skipThreshold) raw of target \(target)"
      )
      return .arrived(start.heightRaw)
    }
    let direction: MoveDirection = target > start.heightRaw ? .up : .down
    log.notice(
      "move #\(id) plan: start=\(start.heightRaw) target=\(target) delta=\(target - start.heightRaw) direction=\(String(describing: direction), privacy: .public)"
    )

    log.notice("move #\(id) prelude: FE 00 then FF 00, both withResponse")
    try await write(DeskCommand.wake.bytes, to: .control, type: .withResponse, for: move)
    try await write(DeskCommand.stop.bytes, to: .control, type: .withResponse, for: move)
    log.notice("move #\(id) prelude acknowledged, starting refresh ticks")

    let startedAt = clock.elapsed
    var moved = false
    var stationaryReads = 0
    var tick = 0
    while true {
      let elapsed = clock.elapsed - startedAt
      if case .hold(_, let input, _) = move.mode {
        guard input.isHeld else {
          log.notice(
            "hold #\(id) dead-man check: input no longer held after \(DeskLog.milliseconds(elapsed)) ms"
          )
          return .released
        }
        if elapsed >= Self.holdLimit {
          log.notice("hold #\(id) reached the \(Self.holdLimit.components.seconds) s cap")
          return .failed(.moveFailed(.holdTimeLimit))
        }
      } else if elapsed >= Self.moveTimeout {
        log.notice(
          "move #\(id) timed out after \(DeskLog.milliseconds(elapsed)) ms (target \(target))")
        return .failed(.moveFailed(.timedOut))
      }

      if let refresh = refreshWrite(for: move, target: target, direction: direction, tick: tick) {
        try await write(refresh.data, to: refresh.characteristic, type: .withoutResponse, for: move)
      } else {
        log.debug("move #\(id) tick \(tick): no refresh write this tick")
      }
      let sample = try await read(for: move)

      if abs(sample.heightRaw - start.heightRaw) >= Self.startThreshold {
        moved = true
      }
      stationaryReads = sample.isStationary ? stationaryReads + 1 : 0
      log.debug(
        "move #\(id) tick \(tick) t=\(DeskLog.milliseconds(elapsed)) ms: \(DeskLog.describe(sample, baseMM: self.baseMM), privacy: .public) target=\(target) remaining=\(target - sample.heightRaw) moved=\(moved) stationaryReads=\(stationaryReads)"
      )
      if !sample.isStationary, (sample.speedRaw > 0) != (direction == .up) {
        log.notice(
          "move #\(id) takeover: speed \(sample.speedRaw) is opposite to the commanded \(String(describing: direction), privacy: .public) at height \(sample.heightRaw)"
        )
        return .failed(.interrupted)
      }
      if stationaryReads >= 2 {
        if abs(sample.heightRaw - target) <= Self.arrivalTolerance {
          log.notice(
            "move #\(id) arrival: stationary at \(sample.heightRaw), target \(target); settle read in \(DeskLog.milliseconds(Self.settleDelay)) ms"
          )
          try await clock.sleep(for: Self.settleDelay)
          try checkCurrent(move)
          let settled = try await read(for: move)
          log.notice(
            "move #\(id) settled: \(DeskLog.describe(settled, baseMM: self.baseMM), privacy: .public) (stationary read said \(sample.heightRaw), target \(target), settled error \(settled.heightRaw - target) raw)"
          )
          return .arrived(settled.heightRaw)
        }
        if moved {
          log.notice(
            "move #\(id) stalled: stationary at \(sample.heightRaw) with target \(target) (\(target - sample.heightRaw) raw away) after \(DeskLog.milliseconds(elapsed)) ms"
          )
          return .failed(.moveFailed(.stalled))
        }
      }
      if !moved, clock.elapsed - startedAt >= Self.didNotStartLimit {
        log.notice(
          "move #\(id) did not start: height still within \(Self.startThreshold) raw of \(start.heightRaw) after \(DeskLog.milliseconds(self.clock.elapsed - startedAt)) ms"
        )
        return .failed(.moveFailed(.didNotStart))
      }

      try await clock.sleep(for: Self.tickInterval)
      try checkCurrent(move)
      tick += 1
    }
  }

  private func refreshWrite(
    for move: ActiveMove, target: Int, direction: MoveDirection, tick: Int
  ) -> (data: Data, characteristic: DeskCharacteristic)? {
    switch move.mode {
    case .target, .relative, .hold(_, _, .targetLimit):
      return (ReferenceInput.target(DeskHeight(clamping: target)), .referenceInput)
    case .hold(_, _, .directionSentinel):
      return (
        direction == .up ? ReferenceInput.directionUp : ReferenceInput.directionDown,
        .referenceInput
      )
    case .hold(_, _, .commandPulses):
      guard tick % Self.pulseEveryTicks == 0 else { return nil }
      return ((direction == .up ? DeskCommand.up : DeskCommand.down).bytes, .control)
    }
  }

  private func checkCurrent(_ move: ActiveMove) throws {
    guard active === move else { throw Superseded() }
  }

  private func read(for move: ActiveMove) async throws -> HeightSample {
    let sample = try await boundedRead()
    publish(sample)
    try checkCurrent(move)
    return sample
  }

  private func boundedRead() async throws -> HeightSample {
    let race = ReadRace()
    let result = await withCheckedContinuation { continuation in
      race.continuation = continuation
      race.timer = Task {
        try? await self.clock.sleep(for: Self.readTimeout)
        race.finish(.failure(DeskTransportError.readFailed("timed out")))
      }
      Task {
        do {
          race.finish(.success(try await self.transport.readHeight()))
        } catch {
          race.finish(.failure(error))
        }
      }
    }
    return try result.get()
  }

  private func write(
    _ data: Data, to characteristic: DeskCharacteristic, type: DeskWriteType,
    for move: ActiveMove
  ) async throws {
    move.hasWritten = true
    try await send(data, to: characteristic, type: type, generation: move.generation)
    try checkCurrent(move)
  }

  @discardableResult
  func send(
    _ data: Data, to characteristic: DeskCharacteristic, type: DeskWriteType,
    generation required: UInt64?
  ) async throws -> Bool {
    let previous = writeTail
    let transport = transport
    let write = Task { () -> Result<Bool, any Error> in
      _ = await previous?.value
      if let required, required != self.generation {
        log.notice(
          "write dropped, stale generation \(required) (current \(self.generation)): \(DeskLog.hex(data), privacy: .public) to \(String(describing: characteristic), privacy: .public)"
        )
        return .success(false)
      }
      if type == .withoutResponse, !transport.canSendWriteWithoutResponse {
        log.notice(
          "write skipped, canSendWriteWithoutResponse is false: \(DeskLog.hex(data), privacy: .public) to \(String(describing: characteristic), privacy: .public)"
        )
        return .success(false)
      }
      do {
        try await transport.write(data, to: characteristic, type: type)
        return .success(true)
      } catch {
        return .failure(error)
      }
    }
    writeTail = write
    return try await write.value.get()
  }

  private func sendStopSequence(verify: Bool) async {
    log.notice("stop sequence: sending FF 00 + 01 80 (verify=\(verify))")
    await sendStopPair()
    guard verify else { return }
    try? await clock.sleep(for: Self.stopVerifyDelay)
    do {
      let sample = try await boundedRead()
      publish(sample)
      log.notice(
        "stop sequence: verify read after \(DeskLog.milliseconds(Self.stopVerifyDelay)) ms: \(DeskLog.describe(sample, baseMM: self.baseMM), privacy: .public)"
      )
      if sample.isStationary { return }
    } catch {
      log.notice(
        "stop sequence: verify read failed: \(String(describing: error), privacy: .public)")
    }
    log.notice("stop sequence: resending FF 00 + 01 80")
    await sendStopPair()
  }

  private func sendStopPair() async {
    do {
      try await send(DeskCommand.stop.bytes, to: .control, type: .withResponse, generation: nil)
    } catch {
      log.error("stop write FF 00 failed: \(String(describing: error), privacy: .public)")
    }
    do {
      try await send(
        ReferenceInput.stop, to: .referenceInput, type: .withResponse, generation: nil)
    } catch {
      log.error("stop write 01 80 failed: \(String(describing: error), privacy: .public)")
    }
  }
}

private enum MoveOutcome {
  case arrived(Int)
  case released
  case failed(DeskControllerError)

  var logDescription: String {
    switch self {
    case .arrived(let raw): "arrived at \(raw)"
    case .released: "released"
    case .failed(let error): "failed(\(String(describing: error)))"
    }
  }
}

private struct Superseded: Error {}

@MainActor
private final class ReadRace {
  var continuation: CheckedContinuation<Result<HeightSample, any Error>, Never>?
  var timer: Task<Void, Never>?

  func finish(_ result: Result<HeightSample, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    continuation.resume(returning: result)
  }
}

@MainActor
private final class ActiveMove {
  enum Mode {
    case target(Int)
    case relative(Int)
    case hold(MoveDirection, any HoldInputSource, HoldVariant)

    var isHold: Bool {
      if case .hold = self { return true }
      return false
    }

    var logDescription: String {
      switch self {
      case .target(let raw): "toTarget raw=\(raw)"
      case .relative(let delta): "relative delta=\(delta)"
      case .hold(let direction, _, let variant):
        "hold direction=\(String(describing: direction)) variant=\(variant.label)"
      }
    }
  }

  let ticket: MoveTicket
  let generation: UInt64
  var mode: Mode
  let endActivity: @MainActor () -> Void
  var loopTask: Task<Void, Never>?
  var hasWritten = false

  init(
    ticket: MoveTicket, generation: UInt64, mode: Mode, endActivity: @escaping @MainActor () -> Void
  ) {
    self.ticket = ticket
    self.generation = generation
    self.mode = mode
    self.endActivity = endActivity
  }
}
