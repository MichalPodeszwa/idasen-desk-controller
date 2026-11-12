import DeskIPC
import DeskKit
import Foundation
import Network

private let log = DeskLog.ipc

@MainActor
public final class ControlServer {
  public enum StartError: Error, Equatable {
    case alreadyRunning
    case pathTooLong(length: Int)
    case setupFailed(String)
    case listenFailed(String)
    case stopped
  }

  public static let defaultConnectTimeout = Duration.seconds(10)

  public let socketPath: String
  private let desk: any DeskControlling
  private let calibrationMM: @MainActor () -> Double
  private let connectTimeout: Duration
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: LineConnection] = [:]
  private var ownsSocketFile = false

  public init(
    desk: any DeskControlling,
    socketPath: String = SocketPath.socketPath(),
    calibrationMM: @escaping @MainActor () -> Double = { 0 },
    connectTimeout: Duration = ControlServer.defaultConnectTimeout
  ) {
    self.desk = desk
    self.socketPath = socketPath
    self.calibrationMM = calibrationMM
    self.connectTimeout = connectTimeout
  }

  public func start() async throws(StartError) {
    guard listener == nil else { return }
    do {
      try SocketPath.validate(socketPath)
    } catch {
      throw .pathTooLong(length: socketPath.utf8.count)
    }
    try prepareDirectory()
    try clearStaleSocket()

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .unix(path: socketPath)
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw .listenFailed(error.localizedDescription)
    }
    listener.newConnectionHandler = { [weak self] connection in
      MainActor.assumeIsolated { self?.accept(connection) }
    }
    self.listener = listener
    do {
      try await ready(listener)
    } catch {
      listener.cancel()
      guard self.listener === listener else { throw .stopped }
      self.listener = nil
      throw .listenFailed(error.localizedDescription)
    }
    ownsSocketFile = true
    log.notice("listening on \(self.socketPath, privacy: .public)")
    guard self.listener === listener else {
      listener.cancel()
      unlinkSocket()
      throw .stopped
    }
    guard chmod(socketPath, 0o600) == 0 else {
      let message = String(cString: strerror(errno))
      listener.cancel()
      self.listener = nil
      unlinkSocket()
      throw .setupFailed("chmod \(socketPath): \(message)")
    }
  }

  public func stop() {
    log.notice("stopping (open connections: \(self.connections.count))")
    listener?.cancel()
    listener = nil
    for connection in connections.values {
      connection.cancel()
    }
    connections = [:]
    unlinkSocket()
  }

  private func prepareDirectory() throws(StartError) {
    let directory = (socketPath as NSString).deletingLastPathComponent
    var isDirectory: ObjCBool = false
    let existed = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
    do {
      if !existed {
        try FileManager.default.createDirectory(
          atPath: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        guard chmod(directory, 0o700) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      } else if !isDirectory.boolValue {
        throw CocoaError(.fileWriteInvalidFileName)
      }
    } catch {
      throw .setupFailed("\(directory): \(error.localizedDescription)")
    }
  }

  private func clearStaleSocket() throws(StartError) {
    let probe: SocketProbe
    do {
      probe = try SocketPath.probe(path: socketPath)
    } catch {
      throw .setupFailed("\(socketPath): \(error.localizedDescription)")
    }
    switch probe {
    case .live:
      log.notice("another instance already owns \(self.socketPath, privacy: .public)")
      throw .alreadyRunning
    case .stale:
      guard unlink(socketPath) == 0 || errno == ENOENT else {
        throw .setupFailed("unlink \(socketPath): \(String(cString: strerror(errno)))")
      }
    case .absent:
      break
    }
  }

  private func unlinkSocket() {
    guard ownsSocketFile else { return }
    ownsSocketFile = false
    unlink(socketPath)
  }

  private func ready(_ listener: NWListener) async throws {
    final class Once: @unchecked Sendable {
      var continuation: CheckedContinuation<Void, any Error>?
    }
    let once = Once()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      once.continuation = continuation
      listener.stateUpdateHandler = { state in
        MainActor.assumeIsolated {
          switch state {
          case .ready:
            once.continuation?.resume()
            once.continuation = nil
          case .failed(let error):
            once.continuation?.resume(throwing: error)
            once.continuation = nil
          case .cancelled:
            once.continuation?.resume(throwing: CancellationError())
            once.continuation = nil
          default:
            break
          }
        }
      }
      listener.start(queue: .main)
    }
  }

  private func accept(_ nwConnection: NWConnection) {
    let connection = LineConnection(connection: nwConnection)
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    Task {
      await serve(connection)
      connection.cancel()
      connections[id] = nil
    }
  }

  private func serve(_ connection: LineConnection) async {
    do {
      try await connection.start()
    } catch {
      return
    }
    let link = ClientLink()
    var handler: Task<Void, Never>?
    do {
      for try await line in connection.lines where handler == nil {
        handler = Task { await handle(line, on: connection, link: link) }
      }
    } catch {
      if handler == nil, case LineFramer.Failure.lineTooLong = error {
        await reply(.failure(.internal, "Request line too long"), on: connection)
      }
    }
    link.close()
    await handler?.value
  }

  private func handle(
    _ line: Data, on connection: LineConnection, link: ClientLink
  ) async {
    let request: Request
    do {
      request = try Request.decode(line)
    } catch {
      let response = failure(for: error)
      log.notice(
        "rejected request (\(line.count) bytes): \(Self.describe(response), privacy: .public)")
      await reply(response, on: connection)
      return
    }
    log.notice("request \(Self.describe(request), privacy: .public)")
    if case .watch = request {
      await watch(on: connection, link: link)
      log.notice("watch client gone")
      return
    }
    let began = ContinuousClock.now
    let response = await execute(request, link: link)
    log.notice(
      "response to \(request.commandName, privacy: .public) after \(DeskLog.milliseconds(began.duration(to: .now))) ms: \(Self.describe(response), privacy: .public)"
    )
    await reply(response, on: connection)
  }

  private nonisolated static func describe(_ request: Request) -> String {
    switch request {
    case .move(.heightCm(let heightCm), let wait):
      "move heightCm=\(heightCm) wait=\(wait)"
    case .move(.position, let wait):
      "move position=<name> wait=\(wait)"
    case .moveBy(let deltaCm, let wait):
      "moveBy deltaCm=\(deltaCm) wait=\(wait)"
    case .positionsSave(_, let heightCm):
      "positions.save heightCm=\(heightCm.map { String($0) } ?? "settled")"
    default:
      request.commandName
    }
  }

  private nonisolated static func describe(_ response: Response) -> String {
    if let error = response.error {
      return error.code == .invalidName
        ? "error \(error.code.rawValue)" : "error \(error.code.rawValue): \(error.message)"
    }
    if let heightCm = response.heightCm { return "ok heightCm=\(heightCm)" }
    if let status = response.status {
      return
        "ok state=\(status.state.rawValue) moving=\(status.moving) heightCm=\(status.heightCm.map { String($0) } ?? "unknown")"
    }
    return "ok"
  }

  private func reply(_ response: Response, on connection: LineConnection) async {
    if let line = try? response.encodedLine() {
      try? await connection.send(line)
    }
    connection.cancel()
  }

  private func failure(for error: RequestError) -> Response {
    switch error {
    case .malformed(let message):
      .failure(.internal, message)
    case .unsupportedVersion(let version):
      .failure(
        .unsupportedVersion,
        "Unsupported protocol version \(version.map(String.init) ?? "none"); this app speaks \(DeskIPC.protocolVersion)"
      )
    case .unsupportedCommand(let command):
      .failure(.unsupported, "Unsupported command '\(command)'")
    }
  }

  private func failure(for error: DeskControllerError) -> Response {
    let code = ErrorCode(rawValue: error.wireCode) ?? .internal
    let message: String
    switch error {
    case .notConnected: message = "Desk is not connected"
    case .outOfRange: message = "Height is out of range"
    case .interrupted: message = "Move was interrupted"
    case .deskMoving: message = "Desk is moving"
    case .moveFailed(.didNotStart): message = "Move failed: the desk did not start moving"
    case .moveFailed(.stalled): message = "Move failed: the desk stalled (obstacle?)"
    case .moveFailed(.timedOut): message = "Move failed: timed out"
    case .moveFailed(.holdTimeLimit): message = "Move failed: hold time limit reached"
    case .moveFailed(.transport(let detail)): message = "Move failed: Bluetooth error (\(detail))"
    case .positions(.unknownPosition): message = "No such position"
    case .positions(.invalidName(.empty)): message = "Position name is empty"
    case .positions(.invalidName(.numeric)): message = "Position name must not be a number"
    case .positions(.invalidName(.numericSlug)):
      message = "Position name must not resolve to a number"
    case .positions(.duplicateName(let clashing)):
      message = "A position named '\(clashing)' already has that name or slug"
    case .positions(.readOnly): message = "Positions file is read-only"
    case .positions(.saveFailed(let detail)): message = "Could not save positions: \(detail)"
    }
    return .failure(code, message)
  }

  private func execute(_ request: Request, link: ClientLink) async -> Response {
    do throws(DeskControllerError) {
      switch request {
      case .status:
        return Response(ok: true, status: statusPayload())
      case .stop:
        await desk.stop()
        return .success
      case .positionsList:
        return Response(ok: true, positions: desk.storedPositions.map { payload($0) })
      case .positionsSave(let name, let heightCm):
        return try await savePosition(name: name, heightCm: heightCm)
      case .positionsRemove(let name):
        try desk.removePosition(named: name)
        return .success
      case .positionsRename(let from, let to):
        try desk.renamePosition(from: from, to: to)
        return .success
      case .connect:
        if !Self.isConnected(desk.state) { desk.connect() }
        guard await awaitConnected() else { throw .notConnected }
        return .success
      case .move(let target, let wait):
        return try await move(to: target, wait: wait, link: link)
      case .moveBy(let deltaCm, let wait):
        try await requireConnected(wait: wait, link: link)
        let delta = Int(min(max((deltaCm * 100).rounded(), -1_000_000), 1_000_000))
        return try await finish(
          desk.beginMove(byRaw: delta), wait: wait, link: link)
      case .watch:
        return .failure(.internal, "watch is a streaming command")
      }
    } catch {
      return failure(for: error)
    }
  }

  private func move(
    to target: MoveTarget, wait: Bool, link: ClientLink
  ) async throws(DeskControllerError) -> Response {
    switch target {
    case .position(let name):
      guard PositionName.match(name, in: desk.storedPositions) != nil else {
        throw .positions(.unknownPosition)
      }
      try await requireConnected(wait: wait, link: link)
      return try await finish(
        desk.beginMove(toPositionNamed: name), wait: wait, link: link)
    case .heightCm(let heightCm):
      try await requireConnected(wait: wait, link: link)
      let height = try rawHeight(cm: heightCm)
      return try await finish(
        desk.beginMove(toRaw: height.raw), wait: wait, link: link)
    }
  }

  private func savePosition(name: String, heightCm: Double?) async throws(DeskControllerError)
    -> Response
  {
    if let heightCm {
      let position = try desk.savePosition(named: name, raw: rawHeight(cm: heightCm).raw)
      return Response(ok: true, position: payload(position))
    }
    guard await awaitConnected() else { throw .notConnected }
    let position = try desk.savePosition(named: name, raw: nil)
    return Response(ok: true, position: payload(position))
  }

  private func finish(
    _ ticket: any DeskMoveTicket, wait: Bool, link: ClientLink
  ) async throws(DeskControllerError) -> Response {
    guard wait else { return .success }
    let id = ticket.id
    let canceller = Task { [desk] in
      await link.closed()
      guard !Task.isCancelled else { return }
      log.notice("client disconnected during waiting move #\(id.rawValue): cancelling it")
      await desk.cancel(moveID: id)
    }
    let result = await ticket.result()
    canceller.cancel()
    return Response(ok: true, heightCm: displayCm(raw: try result.get()))
  }

  private func watch(on connection: LineConnection, link: ClientLink) async {
    let events = desk.watch()
    var current = desk.state
    var state = WireState(current)
    let initial: Event =
      if let heightRaw = desk.heightRaw {
        .height(
          heightCm: displayCm(raw: heightRaw), speedCmS: speedCmS(raw: desk.speedRaw), state: state)
      } else {
        stateEvent(desk.state)
      }
    let pump = Task {
      guard await send(initial, on: connection) else { return }
      for await event in events {
        let next: Event
        switch event {
        case .state(let newState):
          current = newState
          state = WireState(newState)
          next = stateEvent(newState)
        case .notFoundHint:
          next = stateEvent(current)
        case .sample(let sample):
          next = .height(
            heightCm: displayCm(raw: sample.heightRaw), speedCmS: speedCmS(raw: sample.speedRaw),
            state: state)
        }
        guard await send(next, on: connection) else { return }
      }
    }
    await link.closed()
    pump.cancel()
    await pump.value
    connection.cancel()
  }

  private func send(_ event: Event, on connection: LineConnection) async -> Bool {
    guard let line = try? event.encodedLine() else { return true }
    do {
      try await connection.send(line)
      return true
    } catch {
      return false
    }
  }

  private func requireConnected(wait: Bool, link: ClientLink) async throws(DeskControllerError) {
    guard await awaitConnected(abortingWhenClosed: wait ? link : nil) else { throw .notConnected }
    if wait && link.isClosed { throw .interrupted }
  }

  private func awaitConnected(abortingWhenClosed link: ClientLink? = nil) async -> Bool {
    if Self.isConnected(desk.state) { return true }
    let events = desk.watch()
    let timeout = connectTimeout
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask { await Self.connection(in: events) }
      if let link {
        group.addTask { await Self.closure(of: link) }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let connected = await group.next() ?? false
      group.cancelAll()
      return connected
    }
  }

  private nonisolated static func closure(of link: ClientLink) async -> Bool {
    await link.closed()
    return false
  }

  private nonisolated static func connection(in events: AsyncStream<DeskEvent>) async -> Bool {
    for await event in events {
      if case .state(let state) = event, isConnected(state) { return true }
    }
    return false
  }

  private nonisolated static func isConnected(_ state: DeskState) -> Bool {
    if case .connected = state { return true }
    return false
  }

  private func rawHeight(cm: Double) throws(DeskControllerError) -> DeskHeight {
    guard
      let height = DeskHeight(cm: cm, baseMM: desk.baseMM, calibrationMM: calibrationMM())
    else { throw .outOfRange }
    return height
  }

  private func displayCm(raw: Int) -> Double {
    Self.roundedToTenth(
      DeskHeight(clamping: raw).cm(baseMM: desk.baseMM, calibrationMM: calibrationMM()))
  }

  private func speedCmS(raw: Int) -> Double {
    Self.roundedToTenth(Double(raw) / 100)
  }

  private nonisolated static func failureMessage(_ state: DeskState) -> String? {
    if case .failed(let message) = state { return message }
    return nil
  }

  private func stateEvent(_ state: DeskState) -> Event {
    .state(WireState(state), message: Self.failureMessage(state), notFoundHint: desk.notFoundHint)
  }

  private func statusPayload() -> StatusPayload {
    let state = WireState(desk.state)
    return StatusPayload(
      state: state, moving: state == .moving, heightCm: desk.heightRaw.map(displayCm(raw:)),
      minCm: displayCm(raw: DeskHeight.range.lowerBound),
      maxCm: displayCm(raw: DeskHeight.range.upperBound),
      message: Self.failureMessage(desk.state), notFoundHint: desk.notFoundHint)
  }

  private func payload(_ position: Position) -> PositionPayload {
    PositionPayload(
      id: position.id.uuidString, name: position.name,
      slug: PositionName.usableSlug(of: position, in: desk.storedPositions),
      heightCm: displayCm(raw: position.height.raw)
    )
  }

  private static func roundedToTenth(_ value: Double) -> Double {
    let rounded = (value * 10).rounded(.toNearestOrAwayFromZero) / 10
    return rounded == 0 ? 0 : rounded
  }
}

@MainActor
final class ClientLink {
  private(set) var isClosed = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  func close() {
    isClosed = true
    let pending = waiters
    waiters = [:]
    for waiter in pending.values {
      waiter.resume()
    }
  }

  func closed() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if isClosed {
          continuation.resume()
        } else {
          waiters[id] = continuation
        }
      }
    } onCancel: {
      Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
    }
  }
}

extension WireState {
  init(_ state: DeskState) {
    switch state {
    case .bluetoothOff: self = .bluetoothOff
    case .unauthorized: self = .unauthorized
    case .disconnected: self = .disconnected
    case .scanning: self = .scanning
    case .connecting: self = .connecting
    case .pairingRequired: self = .pairingRequired
    case .failed: self = .failed
    case .connected(.idle): self = .connected
    case .connected(.moving): self = .moving
    }
  }
}
