import DeskKitTestSupport
import XCTest

@testable import DeskKit

@MainActor
final class PendingRequestsTests: XCTestCase {
  private var clock: TestClock!
  private var requests: PendingRequests<Int>!

  override func setUp() async throws {
    clock = TestClock()
    requests = PendingRequests<Int>()
  }

  private func wait(timeout: Duration = .seconds(1), started: Counter? = nil) -> Task<
    Result<Int, any Error>, Never
  > {
    Task {
      do {
        return .success(
          try await requests.wait(
            timeout: timeout, clock: clock, timeoutError: DeskTransportError.readFailed("timed out")
          ) { started?.value += 1 })
      } catch {
        return .failure(error)
      }
    }
  }

  @MainActor
  final class Counter {
    var value = 0
  }

  func testStartRunsAfterRegistration() async {
    let counter = Counter()
    let task = wait(started: counter)
    await clock.settle()
    XCTAssertEqual(counter.value, 1)
    XCTAssertEqual(requests.count, 1)
    requests.completeAll(7)
    let result = await task.value
    XCTAssertEqual(try? result.get(), 7)
    XCTAssertEqual(requests.count, 0)
  }

  func testTimesOutWithinBound() async {
    let task = wait(timeout: .seconds(1))
    await clock.advance(by: .milliseconds(999))
    XCTAssertEqual(requests.count, 1)
    await clock.advance(by: .milliseconds(2))
    let result = await task.value
    XCTAssertThrowsError(try result.get()) {
      XCTAssertEqual($0 as? DeskTransportError, .readFailed("timed out"))
    }
    XCTAssertEqual(requests.count, 0)
    XCTAssertEqual(clock.pendingSleepers, 0)
  }

  func testCompleteAllResolvesEveryWaiter() async {
    let first = wait()
    let second = wait()
    await clock.settle()
    requests.completeAll(3)
    let results = await [first.value, second.value]
    XCTAssertEqual(results.compactMap { try? $0.get() }, [3, 3])
    XCTAssertEqual(clock.pendingSleepers, 0)
  }

  func testCompleteFirstResolvesInOrder() async {
    let first = wait()
    await clock.settle()
    let second = wait()
    await clock.settle()
    requests.completeFirst(.success(1))
    let firstResult = await first.value
    XCTAssertEqual(try? firstResult.get(), 1)
    XCTAssertEqual(requests.count, 1)
    requests.completeFirst(.failure(DeskTransportError.writeFailed("x")))
    let secondResult = await second.value
    XCTAssertThrowsError(try secondResult.get())
  }

  func testFailAllOnDisconnectIsImmediate() async {
    let first = wait(timeout: .seconds(30))
    let second = wait(timeout: .seconds(30))
    await clock.settle()
    requests.failAll(DeskTransportError.notConnected)
    let results = await [first.value, second.value]
    for result in results {
      XCTAssertThrowsError(try result.get()) {
        XCTAssertEqual($0 as? DeskTransportError, .notConnected)
      }
    }
    XCTAssertEqual(clock.elapsed, .zero)
    XCTAssertEqual(clock.pendingSleepers, 0)
  }

  func testLateCompletionAfterTimeoutIsIgnored() async {
    let task = wait()
    await clock.advance(by: .seconds(2))
    _ = await task.value
    requests.completeAll(9)
    requests.completeFirst(.success(9))
    XCTAssertEqual(requests.count, 0)
  }

  func testCancellationRemovesWaiter() async {
    let task = wait(timeout: .seconds(30))
    await clock.settle()
    task.cancel()
    await clock.settle()
    let result = await task.value
    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(requests.count, 0)
  }

  private func orderedWait(_ requests: PendingRequests<Void>, timeout: Duration = .seconds(1))
    -> Task<Result<Void, any Error>, Never>
  {
    Task {
      do {
        return .success(
          try await requests.wait(
            timeout: timeout, clock: clock,
            timeoutError: DeskTransportError.writeFailed("timed out")
          ) {})
      } catch {
        return .failure(error)
      }
    }
  }

  func testOrderedTimeoutLeavesTombstoneSoLateAckCannotResolveNextWrite() async {
    let writes = PendingRequests<Void>(ordered: true)
    let first = orderedWait(writes)
    await clock.advance(by: .seconds(2))
    let timedOut = await first.value
    XCTAssertThrowsError(try timedOut.get())
    XCTAssertEqual(writes.count, 1)
    XCTAssertEqual(writes.waiting, 0)

    let second = orderedWait(writes, timeout: .seconds(30))
    await clock.settle()
    writes.completeFirst(.success(()))
    await clock.settle()
    XCTAssertEqual(writes.waiting, 1)
    XCTAssertEqual(writes.count, 1)

    writes.completeFirst(.success(()))
    let result = await second.value
    XCTAssertNoThrow(try result.get())
    XCTAssertEqual(writes.count, 0)
  }

  func testWriteTimeoutFollowedByDropFailsLaterWritesAndLateAckResolvesNothing() async {
    let writes = PendingRequests<Void>(ordered: true)
    let stop = orderedWait(writes)
    await clock.advance(by: .seconds(2))
    _ = await stop.value

    writes.failAll(DeskTransportError.notConnected)
    XCTAssertEqual(writes.count, 0)

    writes.completeFirst(.success(()))
    XCTAssertEqual(writes.count, 0)
    XCTAssertEqual(clock.pendingSleepers, 0)
  }

  func testDropAfterTimeoutFailsWritesStillPendingPromptly() async {
    let writes = PendingRequests<Void>(ordered: true)
    let first = orderedWait(writes, timeout: .seconds(1))
    await clock.settle()
    let second = orderedWait(writes, timeout: .seconds(30))
    await clock.advance(by: .seconds(1))
    _ = await first.value
    let before = clock.elapsed

    writes.failAll(DeskTransportError.notConnected)
    let result = await second.value
    XCTAssertThrowsError(try result.get()) {
      XCTAssertEqual($0 as? DeskTransportError, .notConnected)
    }
    XCTAssertEqual(clock.elapsed, before)
  }

  func testOrderedCancellationLeavesTombstone() async {
    let writes = PendingRequests<Void>(ordered: true)
    let task = orderedWait(writes, timeout: .seconds(30))
    await clock.settle()
    task.cancel()
    await clock.settle()
    let result = await task.value
    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(writes.count, 1)
    XCTAssertEqual(writes.waiting, 0)
  }
}
