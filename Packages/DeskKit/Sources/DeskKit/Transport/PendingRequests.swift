import Foundation

@MainActor
final class PendingRequests<Value: Sendable> {
  private struct Entry {
    let id: Int
    var continuation: CheckedContinuation<Value, any Error>?
    var timer: Task<Void, Never>?
  }

  private let ordered: Bool
  private var entries: [Entry] = []
  private var lastID = 0

  init(ordered: Bool = false) {
    self.ordered = ordered
  }

  var count: Int {
    entries.count
  }

  var waiting: Int {
    entries.filter { $0.continuation != nil }.count
  }

  func wait(
    timeout: Duration, clock: any DeskClock, timeoutError: any Error,
    start: @MainActor () -> Void
  ) async throws -> Value {
    lastID += 1
    let id = lastID
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timer = Task { [weak self] in
          try? await clock.sleep(for: timeout)
          guard !Task.isCancelled else { return }
          self?.abandon(id, with: timeoutError)
        }
        entries.append(Entry(id: id, continuation: continuation, timer: timer))
        start()
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.abandon(id, with: CancellationError()) }
    }
  }

  func completeAll(_ value: Value) {
    let pending = entries
    entries = []
    for entry in pending {
      entry.timer?.cancel()
      entry.continuation?.resume(returning: value)
    }
  }

  func completeFirst(_ result: Result<Value, any Error>) {
    guard !entries.isEmpty else { return }
    let entry = entries.removeFirst()
    entry.timer?.cancel()
    entry.continuation?.resume(with: result)
  }

  func failAll(_ error: any Error) {
    let pending = entries
    entries = []
    for entry in pending {
      entry.timer?.cancel()
      entry.continuation?.resume(throwing: error)
    }
  }

  private func abandon(_ id: Int, with error: any Error) {
    guard let index = entries.firstIndex(where: { $0.id == id }),
      let continuation = entries[index].continuation
    else { return }
    entries[index].timer?.cancel()
    if ordered {
      entries[index].continuation = nil
      entries[index].timer = nil
    } else {
      entries.remove(at: index)
    }
    continuation.resume(throwing: error)
  }
}
