import DeskIPC
import Foundation

struct CLIError: Error, Equatable {
  var status: Int32
  var message: String
  var isUnreachable = false

  static func server(_ error: WireError) -> CLIError {
    let status = error.code.exitStatus
    if status == ExitStatus.versionMismatch {
      return CLIError(
        status: status,
        message:
          "\(error.message). The app and the command line tool versions differ; restart Idasen")
    }
    return CLIError(status: status, message: error.message)
  }
}

struct CLIEnvironment: Sendable {
  var client: any DeskIPCClient
  var launchApp: @Sendable () async -> Bool
  var waitForInterrupt: @Sendable () async -> Bool
  var writeOut: @Sendable (String) -> Void
  var writeErr: @Sendable (String) -> Void
  var launchTimeout: Duration = .seconds(10)
  var deskTimeout: Duration = .seconds(10)
  var pollInterval: Duration = .milliseconds(100)
  var socketPath: String = ""
  var noLaunch = false

  @TaskLocal static var current = CLIEnvironment.live

  static var live: CLIEnvironment {
    let path = SocketPath.socketPath()
    return CLIEnvironment(
      client: IPCClient(socketPath: path),
      launchApp: AppLauncher.launch,
      waitForInterrupt: Interrupt.wait,
      writeOut: { FileHandle.standardOutput.write(Data($0.utf8)) },
      writeErr: { FileHandle.standardError.write(Data($0.utf8)) },
      socketPath: path)
  }

  func out(_ text: String) {
    writeOut(text + "\n")
  }

  func request(_ request: Request) async throws -> Response {
    let response = try await withApp { try await client.send(request) }
    guard response.ok else {
      throw CLIError.server(
        response.error ?? WireError(code: .internal, message: "Request failed"))
    }
    return response
  }

  func withApp<T>(_ operation: () async throws -> T) async throws -> T {
    do {
      return try await translated(operation)
    } catch let error as CLIError where error.isUnreachable {
      guard !noLaunch else {
        throw CLIError(
          status: ExitStatus.appUnavailable,
          message: "The Idasen app is not running (no socket at \(socketPath))")
      }
      guard await launchApp() else {
        throw CLIError(
          status: ExitStatus.appUnavailable, message: "Could not start the Idasen app")
      }
      let deadline = ContinuousClock.now + launchTimeout
      while true {
        try await Task.sleep(for: pollInterval)
        do {
          return try await translated(operation)
        } catch let error as CLIError where error.isUnreachable {
          guard ContinuousClock.now < deadline else {
            throw CLIError(
              status: ExitStatus.appUnavailable,
              message:
                "The Idasen app did not start listening within \(launchTimeout.components.seconds) s"
            )
          }
        }
      }
    }
  }

  private func translated<T>(_ operation: () async throws -> T) async throws -> T {
    do {
      return try await operation()
    } catch IPCClientError.unreachable {
      throw CLIError(
        status: ExitStatus.appUnavailable, message: "The Idasen app is not running",
        isUnreachable: true)
    } catch IPCClientError.pathTooLong(let length) {
      throw CLIError(
        status: ExitStatus.appUnavailable,
        message:
          "The socket path is too long (\(length) bytes, at most \(SocketPath.maxLength)); check \(SocketPath.supportDirectoryVariable)"
      )
    } catch IPCClientError.connectionLost {
      throw CLIError(
        status: ExitStatus.connectionLost, message: "Lost the connection to the Idasen app")
    } catch IPCClientError.malformedResponse {
      throw CLIError(
        status: ExitStatus.failure, message: "The Idasen app sent an unreadable response")
    } catch LineFramer.Failure.lineTooLong {
      throw CLIError(
        status: ExitStatus.failure, message: "The Idasen app sent an oversized response")
    }
  }

  func waitingMove(_ request: Request) async throws -> Response {
    enum Race: Sendable {
      case finished(Response)
      case failed(CLIError)
      case interrupted
      case abandoned
    }
    let race = await withTaskGroup(of: Race.self) { group in
      group.addTask {
        do {
          return .finished(try await self.request(request))
        } catch let error as CLIError {
          return .failed(error)
        } catch is CancellationError {
          return .abandoned
        } catch {
          return .failed(CLIError(status: ExitStatus.failure, message: "\(error)"))
        }
      }
      group.addTask {
        await self.waitForInterrupt() ? .interrupted : .abandoned
      }
      var first = await group.next() ?? .abandoned
      if case .abandoned = first, let second = await group.next() {
        first = second
      }
      group.cancelAll()
      return first
    }
    switch race {
    case .finished(let response): return response
    case .failed(let error): throw error
    case .interrupted, .abandoned: throw CLIError(status: ExitStatus.sigint, message: "")
    }
  }
}
