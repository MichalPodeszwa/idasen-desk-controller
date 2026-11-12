import Foundation

public enum InstallLocation {
  public static let refusalMessage = "Move Idasen to Applications"

  public static func isAcceptable(bundleURL: URL) -> Bool {
    let path = bundleURL.standardizedFileURL.path
    return path.hasPrefix("/Applications/") && !path.contains("/AppTranslocation/")
  }

  public static func refusal(bundleURL: URL) -> String? {
    isAcceptable(bundleURL: bundleURL) ? nil : refusalMessage
  }
}
