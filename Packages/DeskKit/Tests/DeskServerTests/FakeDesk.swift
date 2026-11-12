import DeskKit
import DeskServer
import Foundation

@MainActor
final class FakeTicket: DeskMoveTicket {
  let id: MoveID
  private var outcome: Result<Int, DeskControllerError>?
  private var waiters: [CheckedContinuation<Result<Int, DeskControllerError>, Never>] = []

  init(id: MoveID) {
    self.id = id
  }

  var isResolved: Bool {
    outcome != nil
  }

  func result() async -> Result<Int, DeskControllerError> {
    if let outcome { return outcome }
    return await withCheckedContinuation { waiters.append($0) }
  }

  func resolve(_ result: Result<Int, DeskControllerError>) {
    guard outcome == nil else { return }
    outcome = result
    for waiter in waiters {
      waiter.resume(returning: result)
    }
    waiters = []
  }
}

enum RecordedMove: Equatable {
  case toRaw(Int)
  case byRaw(Int)
  case toPosition(String)
}

@MainActor
final class FakeDesk: DeskControlling {
  var state: DeskState = .connected(.idle)
  var heightRaw: Int? = 3000
  var speedRaw = 0
  var baseMM = 620.0
  var storedPositions: [Position] = []
  var notFoundHint = false

  private(set) var moves: [(move: RecordedMove, ticket: FakeTicket)] = []
  private(set) var cancelled: [MoveID] = []
  private(set) var stopCount = 0
  private(set) var connectCalls = 0
  private(set) var watcherCount = 0
  private var continuations: [UUID: AsyncStream<DeskEvent>.Continuation] = [:]
  private var lastID: UInt64 = 0
  var moveError: DeskControllerError?

  func watch() -> AsyncStream<DeskEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: DeskEvent.self)
    let id = UUID()
    continuations[id] = continuation
    watcherCount += 1
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in
        self?.continuations[id] = nil
        self?.watcherCount -= 1
      }
    }
    return stream
  }

  func emit(_ event: DeskEvent) {
    if case .state(let newState) = event { state = newState }
    for continuation in continuations.values {
      continuation.yield(event)
    }
  }

  func connect() {
    connectCalls += 1
  }

  private func begin(_ move: RecordedMove) throws(DeskControllerError) -> any DeskMoveTicket {
    if let moveError { throw moveError }
    lastID += 1
    let ticket = FakeTicket(id: MoveID(rawValue: lastID))
    moves.append((move, ticket))
    return ticket
  }

  func beginMove(toRaw raw: Int) throws(DeskControllerError) -> any DeskMoveTicket {
    try begin(.toRaw(raw))
  }

  func beginMove(byRaw delta: Int) throws(DeskControllerError) -> any DeskMoveTicket {
    try begin(.byRaw(delta))
  }

  func beginMove(toPositionNamed name: String) throws(DeskControllerError) -> any DeskMoveTicket {
    try begin(.toPosition(name))
  }

  func stop() async {
    stopCount += 1
  }

  func cancel(moveID: MoveID) async {
    cancelled.append(moveID)
  }

  func savePosition(named name: String, raw: Int?) throws(DeskControllerError) -> Position {
    let height: DeskHeight
    if let raw {
      height = DeskHeight(clamping: raw)
    } else {
      guard let heightRaw else { throw .notConnected }
      height = DeskHeight(clamping: heightRaw)
    }
    let position = Position(name: name, height: height)
    storedPositions.append(position)
    return position
  }

  func removePosition(named name: String) throws(DeskControllerError) {
    throw .positions(.unknownPosition)
  }

  func renamePosition(from name: String, to newName: String) throws(DeskControllerError) {
    throw .positions(.unknownPosition)
  }
}
