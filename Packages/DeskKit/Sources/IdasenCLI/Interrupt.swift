import Foundation

enum Interrupt {
  static func wait() async -> Bool {
    signal(SIGINT, SIG_IGN)
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler {
      continuation.yield()
      continuation.finish()
    }
    continuation.onTermination = { _ in
      source.cancel()
      signal(SIGINT, SIG_DFL)
    }
    source.resume()
    for await _ in stream {
      return true
    }
    return false
  }
}
