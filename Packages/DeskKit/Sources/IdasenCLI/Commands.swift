import ArgumentParser
import DeskIPC
import Foundation

// `executeIdasen` strips --no-launch so it works before the command name too; this only documents it in --help.
struct LaunchOptions: ParsableArguments {
  @Flag(name: .customLong("no-launch"), help: "Don't start the Idasen app if it isn't running.")
  var noLaunch = false
}

struct WaitOptions: ParsableArguments {
  @Flag(name: .customLong("no-wait"), help: "Return once the movement has started.")
  var noWait = false
}

struct JSONOptions: ParsableArguments {
  @Flag(name: .customLong("json"), help: "Print machine-readable JSON.")
  var json = false
}

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Show height, connection state and moving flag.")

  @OptionGroup var launch: LaunchOptions
  @OptionGroup var output: JSONOptions

  func run() async throws {
    let env = CLIEnvironment.current
    let response = try await env.request(.status)
    guard let status = response.status else {
      throw CLIError(status: ExitStatus.failure, message: "The app sent no status")
    }
    env.out(output.json ? Format.json(status) : Format.status(status))
  }
}

struct HeightCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "height", abstract: "Print the current height in cm.")

  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    let env = CLIEnvironment.current
    let deadline = ContinuousClock.now + env.deskTimeout
    while true {
      let response = try await env.request(.status)
      guard let status = response.status else {
        throw CLIError(status: ExitStatus.failure, message: "The app sent no status")
      }
      if let height = status.heightCm {
        env.out(Format.cm(height))
        return
      }
      let transitional = ![WireState.bluetoothOff, .unauthorized, .pairingRequired, .failed]
        .contains(status.state)
      guard transitional, ContinuousClock.now < deadline else {
        throw CLIError(
          status: ErrorCode.notConnected.exitStatus,
          message: "Desk is not connected (\(Format.state(status.state, message: status.message)))")
      }
      try await Task.sleep(for: max(env.pollInterval, .milliseconds(250)))
    }
  }
}

private func printSettledHeight(_ response: Response, env: CLIEnvironment) {
  if let height = response.heightCm {
    env.out(Format.cm(height))
  }
}

struct MoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "move", abstract: "Move to a height in cm or to a named position.")

  @Argument(help: "A height in cm (e.g. 105.5), or a position name or slug.")
  var target: String

  @OptionGroup var wait: WaitOptions
  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    let env = CLIEnvironment.current
    let moveTarget: MoveTarget
    if let height = Double(target) {
      guard height.isFinite else {
        throw CLIError(
          status: ErrorCode.outOfRange.exitStatus, message: "Height is out of range")
      }
      moveTarget = .heightCm(height)
    } else {
      moveTarget = .position(target)
    }
    let request = Request.move(moveTarget, wait: !wait.noWait)
    let response =
      wait.noWait
      ? try await env.request(request)
      : try await env.waitingMove(request)
    printSettledHeight(response, env: env)
  }
}

private func relativeMove(
  _ centimetres: Double, direction: Double, wait: WaitOptions, launch: LaunchOptions
) async throws {
  guard centimetres.isFinite, centimetres > 0 else {
    throw ValidationError("The distance must be a positive number of cm.")
  }
  let env = CLIEnvironment.current
  let request = Request.moveBy(deltaCm: centimetres * direction, wait: !wait.noWait)
  let response =
    wait.noWait
    ? try await env.request(request)
    : try await env.waitingMove(request)
  printSettledHeight(response, env: env)
}

struct UpCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "up", abstract: "Move up (default 1 cm).")

  @Argument(help: "Distance in cm.") var centimetres: Double = 1
  @OptionGroup var wait: WaitOptions
  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    try await relativeMove(centimetres, direction: 1, wait: wait, launch: launch)
  }
}

struct DownCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "down", abstract: "Move down (default 1 cm).")

  @Argument(help: "Distance in cm.") var centimetres: Double = 1
  @OptionGroup var wait: WaitOptions
  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    try await relativeMove(centimetres, direction: -1, wait: wait, launch: launch)
  }
}

struct StopCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stop", abstract: "Stop the desk immediately.")

  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    _ = try await CLIEnvironment.current.request(.stop)
  }
}

struct ConnectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "connect", abstract: "Make sure the desk is connected (waits up to 10 s).")

  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    let env = CLIEnvironment.current
    _ = try await env.request(.connect)
    env.out("Connected")
  }
}

struct WatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch", abstract: "Stream height and state changes until Ctrl-C.")

  @OptionGroup var launch: LaunchOptions
  @OptionGroup var output: JSONOptions

  func run() async throws {
    let env = CLIEnvironment.current
    let json = output.json
    try await env.withApp {
      for try await message in env.client.stream(.watch) {
        switch message {
        case .event(let event):
          env.out(json ? Format.json(event) : Format.event(event))
        case .response(let response):
          if !response.ok {
            throw CLIError.server(
              response.error ?? WireError(code: .internal, message: "Request failed"))
          }
        }
      }
      throw IPCClientError.connectionLost
    }
  }
}

struct PositionsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "positions", abstract: "List and edit named positions.",
    subcommands: [
      PositionsListCommand.self, PositionsSaveCommand.self, PositionsRemoveCommand.self,
      PositionsRenameCommand.self,
    ],
    defaultSubcommand: PositionsListCommand.self)
}

struct PositionsListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List positions in display order.")

  @OptionGroup var launch: LaunchOptions
  @OptionGroup var output: JSONOptions

  func run() async throws {
    let env = CLIEnvironment.current
    let response = try await env.request(.positionsList)
    let positions = response.positions ?? []
    if output.json {
      env.out(Format.json(positions))
    } else if positions.isEmpty {
      env.out("No positions saved.")
    } else {
      for position in positions {
        env.out(Format.position(position))
      }
    }
  }
}

struct PositionsSaveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "save", abstract: "Create a position, or update it if the name exists.")

  @Argument(help: "Position name.") var name: String
  @Option(help: "Height in cm. Default: the current settled height.") var height: Double?
  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    let env = CLIEnvironment.current
    if let height, !height.isFinite {
      throw CLIError(
        status: ErrorCode.outOfRange.exitStatus, message: "Height is out of range")
    }
    let response = try await env.request(
      .positionsSave(name: name, heightCm: height))
    if let position = response.position {
      env.out("Saved '\(position.name)' at \(Format.cm(position.heightCm)) cm")
    }
  }
}

struct PositionsRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove", abstract: "Delete a position.")

  @Argument(help: "Position name or slug.") var name: String
  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    let env = CLIEnvironment.current
    _ = try await env.request(.positionsRemove(name: name))
    env.out("Removed '\(name)'")
  }
}

struct PositionsRenameCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rename", abstract: "Rename a position.")

  @Argument(help: "Current name or slug.") var old: String
  @Argument(help: "New name.") var new: String
  @OptionGroup var launch: LaunchOptions

  func run() async throws {
    let env = CLIEnvironment.current
    _ = try await env.request(.positionsRename(from: old, to: new))
    env.out("Renamed '\(old)' to '\(new)'")
  }
}
