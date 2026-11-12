@MainActor
public protocol DeskClock {
  var elapsed: Duration { get }
  func sleep(for duration: Duration) async throws
}

public struct SystemDeskClock<C: Clock<Duration>>: DeskClock {
  private let clock: C
  private let origin: C.Instant

  public init(_ clock: C) {
    self.clock = clock
    origin = clock.now
  }

  public var elapsed: Duration {
    origin.duration(to: clock.now)
  }

  public func sleep(for duration: Duration) async throws {
    try await clock.sleep(for: duration)
  }
}

extension SystemDeskClock where C == ContinuousClock {
  public init() {
    self.init(ContinuousClock())
  }
}
