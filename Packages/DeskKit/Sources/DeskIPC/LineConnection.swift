import Foundation
import Network

public enum IPCClientError: Error, Equatable, Sendable {
  case unreachable
  case connectionLost
  case malformedResponse
  case pathTooLong(length: Int)
}

public final class LineConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "io.github.michalpodeszwa.idasen.line-connection")
  private let lineStream: AsyncThrowingStream<Data, any Error>
  private let lineContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  private var framer = LineFramer()
  private var readyContinuation: CheckedContinuation<Void, any Error>?
  private var started = false
  private var cancelled = false

  public init(connection: NWConnection) {
    self.connection = connection
    (lineStream, lineContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
    lineContinuation.onTermination = { [connection] reason in
      if case .cancelled = reason { connection.cancel() }
    }
  }

  public convenience init(unixPath path: String) {
    let parameters = NWParameters.tcp
    self.init(connection: NWConnection(to: .unix(path: path), using: parameters))
  }

  public var lines: AsyncThrowingStream<Data, any Error> {
    lineStream
  }

  public func start() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { self.begin(continuation) }
      }
    } onCancel: {
      cancel()
    }
  }

  public func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if error == nil {
            continuation.resume()
          } else {
            continuation.resume(throwing: IPCClientError.connectionLost)
          }
        })
    }
  }

  public func cancel() {
    connection.cancel()
    queue.async {
      self.cancelled = true
      self.resumeReady(IPCClientError.unreachable)
    }
  }

  private func begin(_ continuation: CheckedContinuation<Void, any Error>) {
    guard !started, !cancelled else {
      continuation.resume(throwing: IPCClientError.connectionLost)
      return
    }
    started = true
    readyContinuation = continuation
    connection.stateUpdateHandler = { [self] state in
      switch state {
      case .ready:
        resumeReady(nil)
        receive()
      case .waiting, .failed:
        resumeReady(IPCClientError.unreachable)
        connection.cancel()
      case .cancelled:
        resumeReady(IPCClientError.unreachable)
        lineContinuation.finish()
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func resumeReady(_ error: (any Error)?) {
    guard let continuation = readyContinuation else { return }
    readyContinuation = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [self] data, _, isComplete, error in
      if let data, !data.isEmpty {
        do {
          for line in try framer.append(data) {
            lineContinuation.yield(line)
          }
        } catch {
          lineContinuation.finish(throwing: error)
          return
        }
      }
      if error != nil {
        lineContinuation.finish(throwing: IPCClientError.connectionLost)
        connection.cancel()
      } else if isComplete {
        lineContinuation.finish()
      } else {
        receive()
      }
    }
  }
}
