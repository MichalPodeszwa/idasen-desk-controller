import AppKit
import DeskIPC
import Foundation

enum AppLauncher {
  static let releaseBundleIdentifier = "io.github.michalpodeszwa.idasen"

  static func enclosingApp(forExecutable executable: URL) -> URL? {
    let helpers = executable.deletingLastPathComponent()
    let contents = helpers.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
      app.pathExtension == "app"
    else { return nil }
    return app
  }

  static func appBundleIdentifier(cliBundleIdentifier: String?) -> String {
    guard let cliBundleIdentifier, cliBundleIdentifier.hasSuffix(".cli") else {
      #if DEBUG
        return releaseBundleIdentifier + ".debug"
      #else
        return releaseBundleIdentifier
      #endif
    }
    return String(cliBundleIdentifier.dropLast(".cli".count))
  }

  static func launch() async -> Bool {
    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
    let appURL =
      executable.flatMap(enclosingApp(forExecutable:))
      ?? NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: appBundleIdentifier(
          cliBundleIdentifier: Bundle.main.bundleIdentifier))
    guard let appURL else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    if let override = ProcessInfo.processInfo.environment[SocketPath.supportDirectoryVariable] {
      configuration.environment = [SocketPath.supportDirectoryVariable: override]
    }
    do {
      _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
      return true
    } catch {
      return false
    }
  }
}
