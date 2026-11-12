import ArgumentParser
import DeskIPC
import Foundation

public struct IdasenCommand: ParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "idasen",
    abstract: "Control the Idasen menu-bar app and its standing desk.",
    version: versionString(from: Bundle.main.infoDictionary),
    subcommands: [
      StatusCommand.self, HeightCommand.self, MoveCommand.self, UpCommand.self, DownCommand.self,
      StopCommand.self, PositionsCommand.self, WatchCommand.self, ConnectCommand.self,
    ]
  )

  public init() {}

  public func run() throws {
    throw CleanExit.helpRequest(self)
  }
}

public func versionString(from info: [String: Any]?) -> String {
  guard
    let version = info?["CFBundleShortVersionString"] as? String,
    let build = info?["CFBundleVersion"] as? String
  else {
    return "unknown"
  }
  return "\(version) (\(build))"
}

public func exitStatus(for error: any Error) -> Int32 {
  let code = IdasenCommand.exitCode(for: error)
  return code == .validationFailure ? 2 : code.rawValue
}

func executeIdasen(arguments: [String]?, environment: CLIEnvironment) async -> Int32 {
  var environment = environment
  var arguments = arguments ?? Array(CommandLine.arguments.dropFirst())
  if let terminator = arguments.firstIndex(of: "--") {
    let head = arguments[..<terminator].filter { $0 != "--no-launch" }
    environment.noLaunch = head.count != terminator
    arguments = head + arguments[terminator...]
  } else {
    environment.noLaunch = arguments.contains("--no-launch")
    arguments.removeAll { $0 == "--no-launch" }
  }
  let env = environment
  do {
    var command = try IdasenCommand.parseAsRoot(arguments)
    try await CLIEnvironment.$current.withValue(env) {
      if var asyncCommand = command as? any AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    }
    return 0
  } catch let error as CLIError {
    if !error.message.isEmpty {
      env.writeErr("idasen: \(error.message)\n")
    }
    return error.status
  } catch {
    let message = IdasenCommand.fullMessage(for: error)
    let status = exitStatus(for: error)
    if !message.isEmpty {
      let text = message + "\n"
      if status == 0 {
        env.writeOut(text)
      } else {
        env.writeErr(text)
      }
    }
    return status
  }
}

public func runIdasen(arguments: [String]? = nil) async -> Never {
  exit(await executeIdasen(arguments: arguments, environment: .live))
}
