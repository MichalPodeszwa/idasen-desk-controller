import DeskKit
import Foundation

@MainActor
public final class FakeTransport: DeskTransport {
  public struct Write: Equatable, Sendable {
    public let data: Data
    public let characteristic: DeskCharacteristic
    public let type: DeskWriteType
    public let at: Duration
  }

  public private(set) var connectionState: TransportConnectionState
  public var discoveredDesks: [DiscoveredDesk] = []
  public var baseOffsetMM: Double?
  public private(set) var notFoundHint = false
  public var canSendWriteWithoutResponse = true
  public let events: AsyncStream<DeskTransportEvent>
  private let continuation: AsyncStream<DeskTransportEvent>.Continuation
  private let clock: TestClock?

  public private(set) var writes: [Write] = []
  public private(set) var failedWrites: [Write] = []
  public private(set) var readTimes: [Duration] = []
  public var readScript: [HeightSample] = []
  public var nextReadError: (any Error)?
  public var lastRead: HeightSample

  public var holdsWrites = false
  private var heldWrites: [CheckedContinuation<Void, Never>] = []
  public var holdsReads = false
  private var heldReads: [CheckedContinuation<Void, Never>] = []

  public private(set) var connectRequests = 0
  public private(set) var connectToRequests: [DiscoveredDesk.ID] = []
  public private(set) var disconnectRequests = 0
  public private(set) var forgetRequests = 0

  public init(
    clock: TestClock? = nil,
    connectionState: TransportConnectionState = .connected,
    restingSample: HeightSample = HeightSample(heightRaw: 0, speedRaw: 0)
  ) {
    self.clock = clock
    self.connectionState = connectionState
    lastRead = restingSample
    (events, continuation) = AsyncStream.makeStream(of: DeskTransportEvent.self)
  }

  public var heldWriteCount: Int {
    heldWrites.count
  }

  public var heldReadCount: Int {
    heldReads.count
  }

  public func readHeight() async throws -> HeightSample {
    guard connectionState == .connected else { throw DeskTransportError.notConnected }
    readTimes.append(clock?.elapsed ?? .zero)
    if holdsReads {
      await withCheckedContinuation { heldReads.append($0) }
    }
    if let error = nextReadError {
      nextReadError = nil
      throw error
    }
    if !readScript.isEmpty {
      lastRead = readScript.removeFirst()
    }
    return lastRead
  }

  public func write(_ data: Data, to characteristic: DeskCharacteristic, type: DeskWriteType)
    async throws
  {
    let record = Write(
      data: data, characteristic: characteristic, type: type, at: clock?.elapsed ?? .zero)
    guard connectionState == .connected else {
      failedWrites.append(record)
      throw DeskTransportError.notConnected
    }
    writes.append(record)
    if holdsWrites {
      await withCheckedContinuation { heldWrites.append($0) }
    }
  }

  public func releaseHeldWrites() {
    let pending = heldWrites
    heldWrites = []
    for write in pending {
      write.resume()
    }
  }

  public func releaseHeldReads() {
    let pending = heldReads
    heldReads = []
    for read in pending {
      read.resume()
    }
  }

  public func push(_ sample: HeightSample) {
    continuation.yield(.sample(sample))
  }

  public func setConnectionState(_ state: TransportConnectionState) {
    connectionState = state
    continuation.yield(.connectionState(state))
  }

  public func publishDiscoveredDesks(_ desks: [DiscoveredDesk]) {
    discoveredDesks = desks
    continuation.yield(.discoveredDesks(desks))
  }

  public func publishBaseOffset(_ offset: Double?) {
    baseOffsetMM = offset
    continuation.yield(.baseOffset(offset))
  }

  public func publishNotFoundHint(_ hint: Bool) {
    notFoundHint = hint
    continuation.yield(.notFoundHint(hint))
  }

  public func connect() {
    connectRequests += 1
  }

  public func connect(to desk: DiscoveredDesk.ID) {
    connectToRequests.append(desk)
  }

  public func disconnect() {
    disconnectRequests += 1
  }

  public func forget() {
    forgetRequests += 1
  }
}
