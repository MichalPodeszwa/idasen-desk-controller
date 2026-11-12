import CoreBluetooth
import Foundation

private let log = DeskLog.ble

@MainActor
public final class CoreBluetoothTransport: NSObject, DeskTransport {
  public struct Timeouts: Sendable {
    public var read = Duration.seconds(1)
    public var write = Duration.seconds(1)
    public var setup = Duration.seconds(30)
    public var dpgResponse = Duration.seconds(2)

    public init() {}
  }

  private static let writeTimedOut = DeskTransportError.writeFailed("timed out")

  public static var authorization: CBManagerAuthorization {
    CBCentralManager.authorization
  }

  public private(set) var connectionState: TransportConnectionState
  public private(set) var discoveredDesks: [DiscoveredDesk] = []
  public private(set) var baseOffsetMM: Double?
  public private(set) var notFoundHint = false
  public let events: AsyncStream<DeskTransportEvent>

  public var canSendWriteWithoutResponse: Bool {
    connectionState == .connected && (peripheral?.canSendWriteWithoutResponse ?? false)
  }

  private let continuation: AsyncStream<DeskTransportEvent>.Continuation
  private let settings: any DeskSettings
  private let clock: any DeskClock
  private let timeouts: Timeouts
  private let patchesUserID: Bool

  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var known: [UUID: CBPeripheral] = [:]
  private var deskList = DiscoveredDeskList()
  private var plan = DiscoveryPlan()
  private var backoff = ReconnectBackoff()
  private var setup: SetupSequence?
  private var characteristics: [GattCharacteristic: CBCharacteristic] = [:]
  private var awaitingServices: Set<CBUUID> = []
  private var wantsConnection = false
  private var connectedAt: Duration?
  private var setupComplete = false
  private var searchBegan: Duration?

  private var fallbackTask: Task<Void, Never>?
  private var hintTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var setupWatchdog: Task<Void, Never>?
  private var dpgTimer: Task<Void, Never>?

  private let reads = PendingRequests<HeightSample>()
  private let writes = PendingRequests<Void>(ordered: true)

  public init(
    settings: any DeskSettings, clock: any DeskClock = SystemDeskClock(),
    timeouts: Timeouts = Timeouts(), patchesUserID: Bool = false
  ) {
    self.settings = settings
    self.clock = clock
    self.timeouts = timeouts
    self.patchesUserID = patchesUserID
    switch CBCentralManager.authorization {
    case .denied, .restricted: connectionState = .unauthorized
    default: connectionState = .disconnected
    }
    (events, continuation) = AsyncStream.makeStream(of: DeskTransportEvent.self)
    super.init()
  }

  public func activate() {
    guard central == nil else { return }
    let authorization = CBCentralManager.authorization
    log.notice(
      "activate: authorization=\(CoreBluetoothNames.authorization(authorization), privacy: .public)"
    )
    switch authorization {
    case .denied, .restricted:
      setState(.unauthorized)
    default:
      central = CBCentralManager(delegate: self, queue: .main)
    }
  }

  public func connect() {
    wantsConnection = true
    log.notice(
      "connect() requested: central=\(self.central.map { CoreBluetoothNames.state($0.state) } ?? "not created", privacy: .public) hasPeripheral=\(self.peripheral != nil) searching=\(self.plan.isSearching)"
    )
    guard central?.state == .poweredOn, peripheral == nil, !plan.isSearching else { return }
    startDiscovery()
  }

  public func connect(to desk: DiscoveredDesk.ID) {
    wantsConnection = true
    log.notice("connect(to:) requested: \(desk.uuidString, privacy: .public)")
    guard central?.state == .poweredOn, peripheral == nil || plan.isSearching,
      known[desk] != nil
    else { return }
    retryTask?.cancel()
    abandonPendingConnect()
    perform(plan.connectPicked(desk, hintDelay: remainingHintDelay()))
  }

  public func disconnect() {
    wantsConnection = false
    log.notice("disconnect() requested")
    stopDiscovery()
    retryTask?.cancel()
    if let peripheral {
      central?.cancelPeripheralConnection(peripheral)
    }
    dropLink()
    if central?.state == .poweredOn { setState(.disconnected) }
  }

  public func forget() {
    log.notice("forget() requested")
    settings.rememberedPeripheral = nil
    known = [:]
    publishDesks(removingAll: true)
    disconnect()
  }

  public func readHeight() async throws -> HeightSample {
    guard connectionState == .connected, let peripheral,
      let characteristic = characteristics[.referenceOutput]
    else { throw DeskTransportError.notConnected }
    log.debug("read request 99fa0021 (pending reads: \(self.reads.count))")
    do {
      return try await reads.wait(
        timeout: timeouts.read, clock: clock,
        timeoutError: DeskTransportError.readFailed("timed out")
      ) {
        peripheral.readValue(for: characteristic)
      }
    } catch let error as DeskTransportError {
      throw error
    } catch {
      throw DeskTransportError.readFailed(error.localizedDescription)
    }
  }

  public func write(_ data: Data, to characteristic: DeskCharacteristic, type: DeskWriteType)
    async throws
  {
    guard connectionState == .connected, let peripheral else {
      throw DeskTransportError.notConnected
    }
    let target: GattCharacteristic =
      switch characteristic {
      case .control: .control
      case .referenceInput: .referenceInput
      case .dpg: .dpg
      }
    guard let gatt = characteristics[target] else { throw DeskTransportError.notConnected }
    switch type {
    case .withoutResponse:
      log.debug(
        "write \(Self.name(of: gatt), privacy: .public) hex=\(DeskLog.hex(data), privacy: .public) type=withoutResponse canSend=\(peripheral.canSendWriteWithoutResponse)"
      )
      peripheral.writeValue(data, for: gatt, type: .withoutResponse)
    case .withResponse:
      do {
        try await writeWithResponse(data, to: gatt, on: peripheral, timeout: timeouts.write)
      } catch let error as DeskTransportError {
        if error == Self.writeTimedOut { abandonLinkAfterWriteTimeout(peripheral) }
        throw error
      } catch {
        throw DeskTransportError.writeFailed(error.localizedDescription)
      }
    }
  }

  private static func name(of characteristic: CBCharacteristic) -> String {
    let short = characteristic.uuid.uuidString.prefix(8).lowercased()
    let label = GattCharacteristic.allCases.first { CBUUID(string: $0.uuid) == characteristic.uuid }
      .map { " (\($0.label))" }
    return short + (label ?? "")
  }

  private func abandonLinkAfterWriteTimeout(_ timedOut: CBPeripheral) {
    guard timedOut === peripheral else { return }
    log.fault("write timed out, abandoning the link")
    central?.cancelPeripheralConnection(timedOut)
    dropLink()
    apply(.retry)
  }

  private func writeWithResponse(
    _ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral,
    timeout: Duration
  ) async throws {
    let sent = clock.elapsed
    let name = Self.name(of: characteristic)
    do {
      try await writes.wait(
        timeout: timeout, clock: clock, timeoutError: Self.writeTimedOut
      ) {
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
      }
    } catch {
      log.error(
        "write \(name, privacy: .public) hex=\(DeskLog.hex(data), privacy: .public) type=withResponse FAILED after \(DeskLog.milliseconds(self.clock.elapsed - sent)) ms: \(CoreBluetoothNames.error(error), privacy: .public)"
      )
      throw error
    }
    log.notice(
      "write \(name, privacy: .public) hex=\(DeskLog.hex(data), privacy: .public) type=withResponse ack latency=\(DeskLog.milliseconds(self.clock.elapsed - sent)) ms"
    )
  }

  private func setState(_ state: TransportConnectionState) {
    guard state != connectionState else { return }
    log.notice(
      "state \(String(describing: self.connectionState), privacy: .public) -> \(String(describing: state), privacy: .public)"
    )
    connectionState = state
    continuation.yield(.connectionState(state))
    if state != .scanning, notFoundHint { setHint(false) }
  }

  private func setHint(_ hint: Bool) {
    guard hint != notFoundHint else { return }
    log.notice("notFoundHint -> \(hint)")
    notFoundHint = hint
    continuation.yield(.notFoundHint(hint))
  }

  private func publishDesks(removingAll: Bool = false) {
    if removingAll, !deskList.removeAll() { return }
    discoveredDesks = deskList.desks
    continuation.yield(.discoveredDesks(discoveredDesks))
  }

  private func handleCentralState(_ state: CBManagerState) {
    log.notice(
      "central state=\(CoreBluetoothNames.state(state), privacy: .public) authorization=\(CoreBluetoothNames.authorization(CBCentralManager.authorization), privacy: .public)"
    )
    switch state {
    case .poweredOn:
      if wantsConnection, peripheral == nil, !plan.isSearching {
        startDiscovery()
      } else if connectionState == .poweredOff || connectionState == .unauthorized {
        setState(.disconnected)
      }
    case .poweredOff, .unsupported:
      powerLost()
      setState(.poweredOff)
    case .unauthorized:
      powerLost()
      setState(.unauthorized)
    case .resetting:
      powerLost()
      setState(.disconnected)
    case .unknown:
      break
    @unknown default:
      break
    }
  }

  private func powerLost() {
    stopDiscovery()
    retryTask?.cancel()
    dropLink()
    known = [:]
    publishDesks(removingAll: true)
  }

  private func startDiscovery() {
    guard let central, central.state == .poweredOn else { return }
    retryTask?.cancel()
    publishDesks(removingAll: true)
    let remembered = settings.rememberedPeripheral
    let connected = central.retrieveConnectedPeripherals(withServices: [
      CBUUID(string: DeskUUID.advertisedService)
    ])
    let connectedMatch =
      connected.first { $0.identifier == remembered }
      ?? (remembered == nil && connected.count == 1 ? connected.first : nil)
    let rememberedPeripheral = remembered.flatMap {
      central.retrievePeripherals(withIdentifiers: [$0]).first
    }
    log.notice(
      "discovery start: remembered=\(remembered?.uuidString ?? "none", privacy: .public) connectedAtSystemLevel=\(connected.map { $0.identifier.uuidString }.joined(separator: ","), privacy: .public) rememberedKnownToSystem=\(rememberedPeripheral != nil)"
    )
    for peripheral in connected + (rememberedPeripheral.map { [$0] } ?? []) {
      known[peripheral.identifier] = peripheral
    }
    perform(
      plan.start(
        remembered: remembered, connectedAtSystemLevel: connectedMatch?.identifier,
        rememberedKnownToSystem: rememberedPeripheral != nil, hintDelay: remainingHintDelay()))
  }

  private func remainingHintDelay() -> Duration {
    let began = searchBegan ?? clock.elapsed
    searchBegan = began
    return max(.zero, DiscoveryPlan.notFoundHintDelay - (clock.elapsed - began))
  }

  private func stopDiscovery() {
    searchBegan = nil
    perform(plan.stop())
  }

  private func abandonPendingConnect() {
    if let peripheral {
      central?.cancelPeripheralConnection(peripheral)
      self.peripheral = nil
    }
  }

  private func perform(_ actions: [DiscoveryPlan.Action]) {
    for action in actions {
      log.info("discovery action: \(String(describing: action), privacy: .public)")
      switch action {
      case .connect(let id):
        guard let target = known[id] else { continue }
        beginConnect(to: target)
      case .scan(let mode):
        central?.scanForPeripherals(
          withServices: mode == .service ? [CBUUID(string: DeskUUID.advertisedService)] : nil,
          options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        setState(.scanning)
      case .stopScan:
        if central?.state == .poweredOn { central?.stopScan() }
      case .scheduleNameFallback(let delay):
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
          try? await self?.clock.sleep(for: delay)
          guard let self, !Task.isCancelled else { return }
          self.perform(self.plan.nameFallbackFired())
        }
      case .scheduleNotFoundHint(let delay):
        hintTask?.cancel()
        hintTask = Task { [weak self] in
          try? await self?.clock.sleep(for: delay)
          guard let self, !Task.isCancelled else { return }
          self.perform(self.plan.notFoundHintFired())
        }
      case .cancelTimers:
        fallbackTask?.cancel()
        hintTask?.cancel()
      case .setHint(let hint):
        setHint(hint)
      }
    }
  }

  private func beginConnect(to target: CBPeripheral) {
    log.notice(
      "central.connect \(target.identifier.uuidString, privacy: .public) name=\(target.name ?? "nil", privacy: .public)"
    )
    peripheral = target
    target.delegate = self
    central?.connect(target)
    setState(.scanning)
  }

  private func handleDiscovery(
    id: UUID, peripheral discovered: CBPeripheral, name: String?, rssi: Int,
    advertisesService: Bool, advertisedServices: [String]
  ) {
    log.debug(
      "scan result id=\(id.uuidString, privacy: .public) name=\(name ?? "nil", privacy: .public) rssi=\(rssi) advertisesControlService=\(advertisesService) advertisedServices=[\(advertisedServices.joined(separator: ","), privacy: .public)]"
    )
    guard rssi != 127 else { return }
    known[id] = discovered
    if settings.rememberedPeripheral == id, peripheral == nil {
      perform(plan.connectPicked(id, hintDelay: remainingHintDelay()))
      return
    }
    if plan.stage == .scanning(.namePrefix), !advertisesService, !DiscoveryPlan.isDeskName(name) {
      return
    }
    let displayName = name ?? "Desk"
    if deskList.update(id: id, name: displayName, rssi: rssi) {
      log.info(
        "desk list updated: id=\(id.uuidString, privacy: .public) name=\(displayName, privacy: .public) rssi=\(rssi) advertisesControlService=\(advertisesService) advertisedServices=[\(advertisedServices.joined(separator: ","), privacy: .public)]"
      )
      publishDesks()
    }
  }

  private func handleConnected(_ connected: CBPeripheral) {
    log.notice(
      "didConnect \(connected.identifier.uuidString, privacy: .public) expected=\(connected === self.peripheral)"
    )
    guard connected === peripheral else { return }
    searchBegan = nil
    perform(plan.attached())
    retryTask?.cancel()
    connectedAt = clock.elapsed
    setupComplete = false
    setState(.connecting)
    startSetup()
  }

  private func startSetup() {
    log.notice("setup start: patchesUserID=\(self.patchesUserID)")
    var sequence = SetupSequence(patchesUserID: patchesUserID)
    let command = sequence.start()
    setup = sequence
    setupWatchdog?.cancel()
    setupWatchdog = Task { [weak self] in
      try? await self?.clock.sleep(for: self?.timeouts.setup ?? .seconds(30))
      guard let self, !Task.isCancelled, !self.setupComplete else { return }
      log.notice("setup watchdog fired")
      self.failSetup(self.setupTimeoutOutcome())
    }
    run(command)
  }

  private func run(_ command: SetupSequence.Command?) {
    guard let command, let peripheral, setup != nil else { return }
    log.info("setup command: \(Self.describe(command), privacy: .public)")
    switch command {
    case .discoverServices:
      peripheral.discoverServices(GattCharacteristic.serviceUUIDs.map { CBUUID(string: $0) })
    case .discoverCharacteristics:
      let services = (peripheral.services ?? []).filter { service in
        GattCharacteristic.serviceUUIDs.contains { CBUUID(string: $0) == service.uuid }
      }
      awaitingServices = Set(services.map(\.uuid))
      if services.isEmpty {
        run(setup?.characteristicsDiscovered([:]))
      }
      for service in services {
        peripheral.discoverCharacteristics(nil, for: service)
      }
    case .enableNotify(let characteristic):
      guard let gatt = characteristics[characteristic] else { return }
      peripheral.setNotifyValue(true, for: gatt)
    case .writeDPG(let data, let expectsResponse):
      guard let dpg = characteristics[.dpg] else { return }
      let step = setup?.step
      Task { [weak self] in
        guard let self else { return }
        do {
          try await self.writeWithResponse(
            data, to: dpg, on: peripheral, timeout: self.timeouts.dpgResponse)
        } catch {
          self.dpgWriteFailed(error)
          return
        }
        guard self.setup?.step == step else { return }
        if expectsResponse {
          self.armDPGTimer()
        } else {
          self.run(self.setup?.writeCompleted())
        }
      }
    case .finish(let baseOffset):
      completeSetup(baseOffsetMM: baseOffset)
    case .fail(let message):
      failSetup(.fail(message))
    }
  }

  private static func describe(_ command: SetupSequence.Command) -> String {
    switch command {
    case .writeDPG(let data, let expectsResponse):
      "writeDPG hex=\(DeskLog.hex(data)) expectsResponse=\(expectsResponse)"
    default:
      String(describing: command)
    }
  }

  private func armDPGTimer() {
    dpgTimer?.cancel()
    dpgTimer = Task { [weak self] in
      try? await self?.clock.sleep(for: self?.timeouts.dpgResponse ?? .seconds(2))
      guard let self, !Task.isCancelled else { return }
      log.notice("DPG response timed out")
      self.run(self.setup?.dpgUnavailable())
    }
  }

  private func dpgWriteFailed(_ error: any Error) {
    guard setup != nil else { return }
    log.notice("DPG write failed: \(CoreBluetoothNames.error(error), privacy: .public)")
    if error is CancellationError { return }
    if let outcome = pairingOutcome(for: error) {
      failSetup(outcome)
    } else if (error as? DeskTransportError) == .notConnected {
      return
    } else {
      run(setup?.dpgUnavailable())
    }
  }

  private func setupTimeoutOutcome() -> LinkFailure {
    wasSetUpBefore ? .retry : .pairingRequired(.pairingModeNeeded)
  }

  private var wasSetUpBefore: Bool {
    guard let identifier = peripheral?.identifier else { return false }
    return settings.rememberedPeripheral == identifier
  }

  private func pairingOutcome(for error: any Error) -> LinkFailure? {
    guard let reason = TransportErrorMapping.pairingReason(for: error) else { return nil }
    return .pairingRequired(reason)
  }

  private func completeSetup(baseOffsetMM offset: Double?) {
    let took = connectedAt.map { DeskLog.milliseconds(clock.elapsed - $0) } ?? -1
    log.notice(
      "setup complete after \(took) ms: baseOffsetMM=\(offset.map { String($0) } ?? "nil (fallback 620.0)", privacy: .public) patchesUserID=\(self.patchesUserID)"
    )
    setupWatchdog?.cancel()
    dpgTimer?.cancel()
    setupComplete = true
    setup = nil
    backoff.reset()
    baseOffsetMM = offset
    continuation.yield(.baseOffset(offset))
    if let identifier = peripheral?.identifier, settings.rememberedPeripheral != identifier {
      settings.rememberedPeripheral = identifier
    }
    setState(.connected)
    Task { [weak self] in
      _ = try? await self?.readHeight()
    }
  }

  private func failSetup(_ failure: LinkFailure) {
    guard setup != nil else { return }
    log.notice(
      "setup failed at step \(String(describing: self.setup?.step), privacy: .public) -> \(String(describing: failure), privacy: .public)"
    )
    if let peripheral {
      central?.cancelPeripheralConnection(peripheral)
    }
    dropLink()
    apply(failure)
  }

  private func apply(_ failure: LinkFailure) {
    log.notice("link outcome: \(String(describing: failure), privacy: .public)")
    switch failure {
    case .pairingRequired(let reason):
      setState(.pairingRequired(reason))
    case .fail(let message):
      wantsConnection = false
      setState(.failed(message))
    case .retry:
      scheduleRetry()
    case .reconnect:
      setState(.disconnected)
      if wantsConnection { startDiscovery() }
    }
  }

  private func scheduleRetry() {
    guard wantsConnection else {
      setState(.disconnected)
      return
    }
    setState(.scanning)
    let delay = backoff.nextDelay()
    log.notice("retry scheduled in \(DeskLog.milliseconds(delay)) ms")
    retryTask?.cancel()
    retryTask = Task { [weak self] in
      try? await self?.clock.sleep(for: delay)
      guard let self, !Task.isCancelled, self.wantsConnection, self.peripheral == nil else {
        return
      }
      self.startDiscovery()
    }
  }

  private func dropLink() {
    if peripheral != nil {
      log.info(
        "dropLink: failing \(self.reads.count) pending reads and \(self.writes.count) pending writes"
      )
    }
    setupWatchdog?.cancel()
    dpgTimer?.cancel()
    reads.failAll(DeskTransportError.notConnected)
    writes.failAll(DeskTransportError.notConnected)
    peripheral = nil
    characteristics = [:]
    awaitingServices = []
    setup = nil
    setupComplete = false
    connectedAt = nil
  }

  private func handleDisconnect(_ lost: CBPeripheral, error: (any Error)?) {
    guard lost === peripheral else {
      log.info(
        "didDisconnect for an unexpected peripheral \(lost.identifier.uuidString, privacy: .public) error=\(CoreBluetoothNames.error(error), privacy: .public)"
      )
      return
    }
    let sinceConnect = connectedAt.map { clock.elapsed - $0 } ?? .zero
    let outcome = TransportErrorMapping.classifyDisconnect(
      error, setupComplete: setupComplete, sinceConnect: sinceConnect,
      wasSetUpBefore: wasSetUpBefore)
    log.notice(
      "didDisconnect \(lost.identifier.uuidString, privacy: .public) error=\(CoreBluetoothNames.error(error), privacy: .public) sinceConnect=\(DeskLog.milliseconds(sinceConnect)) ms setupComplete=\(self.setupComplete) wasSetUpBefore=\(self.wasSetUpBefore) classified=\(String(describing: outcome), privacy: .public)"
    )
    dropLink()
    apply(outcome)
  }

  private func handleFailedConnect(_ failed: CBPeripheral, error: (any Error)?) {
    let outcome = TransportErrorMapping.classifyConnectFailure(error)
    log.notice(
      "didFailToConnect \(failed.identifier.uuidString, privacy: .public) error=\(CoreBluetoothNames.error(error), privacy: .public) expected=\(failed === self.peripheral) classified=\(String(describing: outcome), privacy: .public)"
    )
    guard failed === peripheral else { return }
    dropLink()
    apply(outcome)
  }

  private func handleServices(error: (any Error)?) {
    let services = (peripheral?.services ?? []).map { $0.uuid.uuidString.lowercased() }
    log.notice(
      "didDiscoverServices error=\(CoreBluetoothNames.error(error), privacy: .public) services=[\(services.joined(separator: ", "), privacy: .public)]"
    )
    if let error {
      failSetup(TransportErrorMapping.classifySetupFailure(error))
      return
    }
    run(setup?.servicesDiscovered())
  }

  private func handleCharacteristics(
    of service: CBService, error: (any Error)?
  ) {
    log.notice(
      "didDiscoverCharacteristics service=\(service.uuid.uuidString.lowercased(), privacy: .public) error=\(CoreBluetoothNames.error(error), privacy: .public)"
    )
    for characteristic in service.characteristics ?? [] {
      log.notice(
        "  characteristic \(characteristic.uuid.uuidString.lowercased(), privacy: .public) properties=\(CoreBluetoothNames.properties(characteristic.properties), privacy: .public)"
      )
    }
    if let error {
      failSetup(TransportErrorMapping.classifySetupFailure(error))
      return
    }
    for characteristic in service.characteristics ?? [] {
      if let known = GattCharacteristic.allCases.first(where: {
        CBUUID(string: $0.uuid) == characteristic.uuid
      }) {
        characteristics[known] = characteristic
      }
    }
    awaitingServices.remove(service.uuid)
    guard awaitingServices.isEmpty, setup != nil else { return }
    let found = characteristics.mapValues { GattProperties(rawValue: $0.properties.rawValue) }
    run(setup?.characteristicsDiscovered(found))
  }

  private func handleNotifyState(of characteristic: CBCharacteristic, error: (any Error)?) {
    log.notice(
      "notify state \(Self.name(of: characteristic), privacy: .public) isNotifying=\(characteristic.isNotifying) error=\(CoreBluetoothNames.error(error), privacy: .public)"
    )
    if let error {
      failSetup(TransportErrorMapping.classifySetupFailure(error))
      return
    }
    guard setup != nil, !setupComplete else { return }
    run(setup?.notifyEnabled())
  }

  private func handleValue(of characteristic: CBCharacteristic, value: Data?, error: (any Error)?) {
    if characteristic.uuid == CBUUID(string: DeskUUID.referenceOutput) {
      if let error {
        log.error(
          "99fa0021 update failed: \(CoreBluetoothNames.error(error), privacy: .public) (pending reads: \(self.reads.count))"
        )
        reads.failAll(DeskTransportError.readFailed(error.localizedDescription))
        return
      }
      guard let value, let sample = try? HeightSample(decoding: value) else {
        log.error(
          "99fa0021 update could not be decoded: hex=\(DeskLog.hex(value ?? Data()), privacy: .public)"
        )
        return
      }
      log.debug(
        "99fa0021 value (read response or notification) hex=\(DeskLog.hex(value), privacy: .public) \(DeskLog.describe(sample, baseMM: self.baseOffsetMM ?? DeskHeight.defaultBaseMM), privacy: .public) source=\(self.reads.count == 0 ? "notification" : "read-or-notification", privacy: .public) pendingReads=\(self.reads.count) setupComplete=\(self.setupComplete)"
      )
      reads.completeAll(sample)
      guard connectionState == .connected else { return }
      continuation.yield(.sample(sample))
    } else if characteristic.uuid == CBUUID(string: DeskUUID.dpg) {
      let step = String(describing: setup?.step)
      log.notice(
        "DPG response hex=\(DeskLog.hex(value ?? Data()), privacy: .public) error=\(CoreBluetoothNames.error(error), privacy: .public) step=\(step, privacy: .public) status=\(value.flatMap { $0.first.map { String(format: "%02X", $0) } } ?? "none", privacy: .public) payload=\(value.flatMap { DPG.payload(of: $0) }.map { DeskLog.hex($0) } ?? "invalid", privacy: .public) baseOffsetMM=\(value.flatMap { DPG.parseBaseOffsetMM($0) }.map { String($0) } ?? "n/a", privacy: .public)"
      )
      guard error == nil, let value, setup?.isWaitingForDPGResponse == true else { return }
      dpgTimer?.cancel()
      run(setup?.dpgResponse(value))
    } else {
      log.notice(
        "value update \(Self.name(of: characteristic), privacy: .public) hex=\(DeskLog.hex(value ?? Data()), privacy: .public) error=\(CoreBluetoothNames.error(error), privacy: .public)"
      )
    }
  }

  private func handleWrite(of characteristic: CBCharacteristic, error: (any Error)?) {
    log.debug(
      "didWriteValueFor \(Self.name(of: characteristic), privacy: .public) error=\(CoreBluetoothNames.error(error), privacy: .public) pendingWrites=\(self.writes.count)"
    )
    if let error {
      writes.completeFirst(.failure(error))
    } else {
      writes.completeFirst(.success(()))
    }
  }
}

private struct MainQueueBox<Value>: @unchecked Sendable {
  let value: Value
}

extension CoreBluetoothTransport: CBCentralManagerDelegate {
  nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let state = central.state
    MainActor.assumeIsolated { handleCentralState(state) }
  }

  nonisolated public func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi rssiValue: NSNumber
  ) {
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
    let id = peripheral.identifier
    let rssi = rssiValue.intValue
    let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let advertisesService = services.contains(CBUUID(string: DeskUUID.advertisedService))
    let advertisedServices = services.map { $0.uuidString.lowercased() }
    let box = MainQueueBox(value: peripheral)
    MainActor.assumeIsolated {
      handleDiscovery(
        id: id, peripheral: box.value, name: name, rssi: rssi, advertisesService: advertisesService,
        advertisedServices: advertisedServices)
    }
  }

  nonisolated public func centralManager(
    _ central: CBCentralManager, didConnect peripheral: CBPeripheral
  ) {
    let box = MainQueueBox(value: peripheral)
    MainActor.assumeIsolated { handleConnected(box.value) }
  }

  nonisolated public func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?
  ) {
    let box = MainQueueBox(value: peripheral)
    MainActor.assumeIsolated { handleFailedConnect(box.value, error: error) }
  }

  nonisolated public func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
    error: (any Error)?
  ) {
    let box = MainQueueBox(value: peripheral)
    MainActor.assumeIsolated { handleDisconnect(box.value, error: error) }
  }
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
  nonisolated public func peripheral(
    _ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?
  ) {
    MainActor.assumeIsolated { handleServices(error: error) }
  }

  nonisolated public func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
    error: (any Error)?
  ) {
    let box = MainQueueBox(value: service)
    MainActor.assumeIsolated { handleCharacteristics(of: box.value, error: error) }
  }

  nonisolated public func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    let box = MainQueueBox(value: characteristic)
    MainActor.assumeIsolated { handleNotifyState(of: box.value, error: error) }
  }

  nonisolated public func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    let value = characteristic.value
    let box = MainQueueBox(value: characteristic)
    MainActor.assumeIsolated { handleValue(of: box.value, value: value, error: error) }
  }

  nonisolated public func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    let box = MainQueueBox(value: characteristic)
    MainActor.assumeIsolated { handleWrite(of: box.value, error: error) }
  }
}
