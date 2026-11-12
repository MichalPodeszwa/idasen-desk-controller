import Foundation

public struct CLIInstaller: Sendable {
  public enum Status: Equatable, Sendable {
    case notInstalled
    case installed
    case pointsElsewhere(String)
    case blockedByFile
  }

  public enum InstallError: Error, Equatable, Sendable {
    case blockedByFile(String)
    case failed(String)
  }

  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".local/bin", directoryHint: .isDirectory)
  }

  public let helperURL: URL
  public let directory: URL

  public var linkURL: URL {
    directory.appending(path: "idasen")
  }

  public init(helperURL: URL, directory: URL = CLIInstaller.defaultDirectory) {
    self.helperURL = helperURL
    self.directory = directory
  }

  public func status() -> Status {
    let fileManager = FileManager.default
    guard let attributes = try? fileManager.attributesOfItem(atPath: linkURL.path) else {
      return .notInstalled
    }
    guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
      return .blockedByFile
    }
    guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) else {
      return .notInstalled
    }
    return destination == helperURL.path ? .installed : .pointsElsewhere(destination)
  }

  public func install() throws(InstallError) {
    if status() == .blockedByFile { throw .blockedByFile(linkURL.path) }
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      if (try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)) != nil {
        try fileManager.removeItem(at: linkURL)
      }
      try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: helperURL)
    } catch {
      throw .failed(error.localizedDescription)
    }
  }

  public func uninstall() throws(InstallError) {
    guard status() != .blockedByFile else { throw .blockedByFile(linkURL.path) }
    do {
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil {
        try FileManager.default.removeItem(at: linkURL)
      }
    } catch {
      throw .failed(error.localizedDescription)
    }
  }

  public func isOnPath(_ pathVariable: String?) -> Bool {
    let target = directory.standardizedFileURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return (pathVariable ?? "").split(separator: ":").contains { entry in
      let expanded =
        entry.hasPrefix("~/") ? home + entry.dropFirst(1) : String(entry)
      return URL(fileURLWithPath: expanded).standardizedFileURL.path == target
    }
  }
}
