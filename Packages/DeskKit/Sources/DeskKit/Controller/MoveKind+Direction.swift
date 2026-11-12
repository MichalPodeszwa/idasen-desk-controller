extension MoveKind {
  public func direction(currentRaw: Int?) -> MoveDirection {
    switch self {
    case .toTarget(let raw, _):
      guard let currentRaw else { return .up }
      return raw < currentRaw ? .down : .up
    case .relative(let deltaRaw, _): return deltaRaw < 0 ? .down : .up
    case .hold(let direction, _), .external(let direction): return direction
    }
  }
}
