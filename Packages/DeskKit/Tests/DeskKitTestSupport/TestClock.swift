import DeskKit

@MainActor
public final class TestClock: DeskClock {
  private struct Sleeper {
    let id: Int
    let deadline: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }

  private static let settleYields = 200

  public private(set) var elapsed: Duration = .zero
  private var sleepers: [Sleeper] = []
  private var lastSleeperID = 0

  public init() {}

  public var pendingSleepers: Int {
    sleepers.count
  }

  public func sleep(for duration: Duration) async throws {
    lastSleeperID += 1
    let id = lastSleeperID
    let deadline = elapsed + duration
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        register(Sleeper(id: id, deadline: deadline, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor in self.cancelSleeper(id) }
    }
  }

  private func register(_ sleeper: Sleeper) {
    if Task.isCancelled {
      sleeper.continuation.resume(throwing: CancellationError())
    } else {
      sleepers.append(sleeper)
    }
  }

  public func advance(by duration: Duration) async {
    await settle()
    let target = elapsed + duration
    while let next = sleepers.map(\.deadline).min(), next <= target {
      elapsed = next
      let due = sleepers.filter { $0.deadline <= next }
      sleepers.removeAll { $0.deadline <= next }
      for sleeper in due {
        sleeper.continuation.resume()
      }
      await settle()
    }
    elapsed = target
    await settle()
  }

  public func settle() async {
    for _ in 0..<Self.settleYields {
      await Task.yield()
    }
  }

  private func cancelSleeper(_ id: Int) {
    guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
    sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}
