import Foundation
import os

public enum DeskLog {
  public static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.michalpodeszwa.idasen"

  public static let ble = Logger(subsystem: subsystem, category: "ble")
  public static let controller = Logger(subsystem: subsystem, category: "controller")
  public static let ipc = Logger(subsystem: subsystem, category: "ipc")
  public static let app = Logger(subsystem: subsystem, category: "app")

  public static func hex(_ data: Data) -> String {
    data.isEmpty ? "(empty)" : data.map { String(format: "%02X", $0) }.joined(separator: " ")
  }

  public static func milliseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
  }

  public static func describe(_ error: any Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)"
  }

  public static func describe(_ sample: HeightSample, baseMM: Double) -> String {
    let heightMM = Double(sample.heightRaw) / 10 + baseMM
    return
      "height=\(sample.heightRaw) raw (\(String(format: "%.1f", heightMM)) mm) speed=\(sample.speedRaw) raw (\(String(format: "%.1f", sample.speedMMPerSecond)) mm/s)"
  }
}

extension DeskState {
  var logDescription: String {
    switch self {
    case .connected(.idle): "connected/idle"
    case .connected(.moving(let kind)): "connected/moving(\(kind.logDescription))"
    case .pairingRequired(let reason): "pairingRequired(\(reason))"
    case .failed(let message): "failed(\(message))"
    default: String(describing: self)
    }
  }
}

extension MoveKind {
  var logDescription: String {
    switch self {
    case .toTarget(let raw, let id): "toTarget raw=\(raw) #\(id.rawValue)"
    case .relative(let delta, let id): "relative delta=\(delta) #\(id.rawValue)"
    case .hold(let direction, let id): "hold \(direction) #\(id.rawValue)"
    case .external(let direction): "external \(direction)"
    }
  }
}
