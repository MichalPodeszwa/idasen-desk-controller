public struct MoveID: Hashable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public enum MoveDirection: Sendable {
  case up
  case down
}

public enum MoveKind: Equatable, Sendable {
  case toTarget(raw: Int, id: MoveID)
  case relative(deltaRaw: Int, id: MoveID)
  case hold(MoveDirection, id: MoveID)
  case external(MoveDirection)
}

public enum DeskActivity: Equatable, Sendable {
  case idle
  case moving(MoveKind)
}

public enum DeskState: Equatable, Sendable {
  case bluetoothOff
  case unauthorized
  case disconnected
  case scanning
  case connecting
  case pairingRequired(PairingReason)
  case failed(String)
  case connected(DeskActivity)
}

public enum MoveFailure: Equatable, Sendable {
  case didNotStart
  case stalled
  case timedOut
  case holdTimeLimit
  case transport(String)
}

public enum DeskControllerError: Error, Equatable, Sendable {
  case notConnected
  case outOfRange
  case interrupted
  case deskMoving
  case moveFailed(MoveFailure)
  case positions(PositionError)

  public var wireCode: String {
    switch self {
    case .notConnected: "notConnected"
    case .outOfRange: "outOfRange"
    case .interrupted: "interrupted"
    case .deskMoving: "deskMoving"
    case .moveFailed: "moveFailed"
    case .positions(.unknownPosition): "unknownPosition"
    case .positions(.invalidName), .positions(.duplicateName): "invalidName"
    case .positions(.readOnly): "positionsReadOnly"
    case .positions(.saveFailed): "internal"
    }
  }
}

public enum DeskEvent: Equatable, Sendable {
  case sample(HeightSample)
  case state(DeskState)
  case notFoundHint(Bool)
}

public enum HoldVariant: Sendable {
  case targetLimit
  case commandPulses
  case directionSentinel
}

@MainActor
public protocol HoldInputSource {
  var isHeld: Bool { get }
}

@MainActor
public final class MoveTicket {
  public let id: MoveID
  private var outcome: Result<Int, DeskControllerError>?
  private var waiters: [CheckedContinuation<Result<Int, DeskControllerError>, Never>] = []

  init(id: MoveID) {
    self.id = id
  }

  public var isFinished: Bool {
    outcome != nil
  }

  public func result() async -> Result<Int, DeskControllerError> {
    if let outcome { return outcome }
    return await withCheckedContinuation { waiters.append($0) }
  }

  public func value() async throws(DeskControllerError) -> Int {
    try await result().get()
  }

  func resolve(_ result: Result<Int, DeskControllerError>) {
    guard outcome == nil else { return }
    outcome = result
    let pending = waiters
    waiters = []
    for waiter in pending {
      waiter.resume(returning: result)
    }
  }
}
