import DeskIPC
import Foundation

enum Format {
  static func cm(_ value: Double) -> String {
    let tenths = Int((value * 10).rounded(.toNearestOrAwayFromZero))
    let sign = tenths < 0 ? "-" : ""
    return "\(sign)\(abs(tenths) / 10).\(abs(tenths) % 10)"
  }

  static func json(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
  }

  static func status(_ status: StatusPayload) -> String {
    let height = status.heightCm.map { "\(cm($0)) cm" } ?? "unknown"
    var text = """
      State:  \(state(status.state, message: status.message))
      Height: \(height)
      Range:  \(cm(status.minCm))–\(cm(status.maxCm)) cm
      """
    if status.notFoundHint {
      text += "\n\(notFoundText)"
    }
    return text
  }

  static let notFoundText =
    "Desk not found: it may be off, out of range or connected to another device."

  static func state(_ state: WireState, message: String?) -> String {
    guard let message, !message.isEmpty else { return state.rawValue }
    return "\(state.rawValue) (\(message))"
  }

  static func position(_ position: PositionPayload) -> String {
    "\(position.name)  \(position.slug.isEmpty ? "-" : position.slug)  \(cm(position.heightCm)) cm"
  }

  static func event(_ event: Event) -> String {
    switch event {
    case .height(let heightCm, let speedCmS, let state):
      "\(cm(heightCm)) cm  \(state.rawValue)  \(cm(speedCmS)) cm/s"
    case .state(let state, let message, let notFoundHint):
      "state: \(Self.state(state, message: message))" + (notFoundHint ? "\n\(notFoundText)" : "")
    }
  }
}
