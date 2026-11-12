import Foundation

public enum SocketPathError: Error, Equatable, Sendable {
  case tooLong(length: Int)
}

public enum SocketProbe: Equatable, Sendable {
  case live
  case stale
  case absent
}

public enum SocketPath {
  public static let supportDirectoryVariable = "IDASEN_SUPPORT_DIR"
  public static let fileName = "control.sock"
  public static let maxLength = 103

  #if DEBUG
    static let directoryName = "Idasen-Debug"
  #else
    static let directoryName = "Idasen"
  #endif

  public static func supportDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let override = environment[supportDirectoryVariable], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support", directoryHint: .isDirectory)
      .appending(path: directoryName, directoryHint: .isDirectory)
  }

  public static func socketPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    supportDirectory(environment: environment).appending(path: fileName).path
  }

  public static func validate(_ path: String) throws(SocketPathError) {
    let length = path.utf8.count
    guard length <= maxLength else { throw .tooLong(length: length) }
  }

  public static func probe(path: String) throws -> SocketProbe {
    try validate(path)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in path.utf8.enumerated() {
        buffer[index] = byte
      }
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result == 0 { return .live }
    switch errno {
    case ENOENT: return .absent
    case ECONNREFUSED, ENOTSOCK: return .stale
    case EAGAIN, EINPROGRESS: return .live
    default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
