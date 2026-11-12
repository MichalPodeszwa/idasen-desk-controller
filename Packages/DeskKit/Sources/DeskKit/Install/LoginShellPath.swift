import Foundation

public enum LoginShellPath {
  public static let marker = "__IDASEN_PATH__"

  public static func resolve(
    shell: String? = ProcessInfo.processInfo.environment["SHELL"],
    timeout: Duration = .seconds(3)
  ) async -> String? {
    guard let shell, !shell.isEmpty else { return nil }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: run(shell: shell, timeout: timeout))
      }
    }
  }

  static func extract(from output: String) -> String? {
    guard let range = output.range(of: marker, options: .backwards) else { return nil }
    let path = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  private static func run(shell: String, timeout: Duration) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lc", "printf '%s%s' '\(marker)' \"$PATH\""]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      return nil
    }
    let components = timeout.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    guard finished.wait(timeout: .now() + seconds) == .success else {
      process.terminate()
      return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else { return nil }
    return extract(from: String(decoding: data, as: UTF8.self))
  }
}
