import Foundation

public protocol DeskIPCClient: Sendable {
  func send(_ request: Request) async throws -> Response
  func stream(_ request: Request) -> AsyncThrowingStream<ServerMessage, any Error>
}

public struct IPCClient: DeskIPCClient {
  public let socketPath: String

  public init(socketPath: String = SocketPath.socketPath()) {
    self.socketPath = socketPath
  }

  public func send(_ request: Request) async throws -> Response {
    for try await message in stream(request) {
      if case .response(let response) = message { return response }
    }
    try Task.checkCancellation()
    throw IPCClientError.connectionLost
  }

  public func stream(_ request: Request) -> AsyncThrowingStream<ServerMessage, any Error> {
    let path = socketPath
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          do {
            try SocketPath.validate(path)
          } catch {
            throw IPCClientError.pathTooLong(length: path.utf8.count)
          }
          let connection = LineConnection(unixPath: path)
          defer { connection.cancel() }
          try await connection.start()
          do {
            try await connection.send(try request.encodedLine())
            for try await line in connection.lines {
              do {
                continuation.yield(try ServerMessage.decode(line))
              } catch {
                throw IPCClientError.malformedResponse
              }
            }
          } catch let error as IPCClientError {
            throw error
          } catch is CancellationError {
            throw CancellationError()
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
