import CoreBluetooth
import DeskKit
import Foundation

enum Formatting {
  static func cm(_ value: Double) -> String {
    String(format: "%.1f", value)
  }

  static func status(for state: DeskState, notFoundHint: Bool) -> String {
    switch state {
    case .bluetoothOff: "Bluetooth is off"
    case .unauthorized: "Bluetooth access is denied"
    case .disconnected: "Disconnected"
    case .scanning:
      notFoundHint
        ? "Desk not found: is it on, in range, and not connected to another device?"
        : "Searching for the desk…"
    case .connecting: "Connecting…"
    case .pairingRequired(.pairingModeNeeded):
      "Hold the Bluetooth button on the desk until it blinks"
    case .pairingRequired(.bondRemovedByDesk):
      "Remove the desk in System Settings → Bluetooth, then pair again"
    case .failed(let message): message
    case .connected(.idle): "Connected"
    case .connected(.moving(.hold(let direction, _))): "Moving \(word(direction)) (holding)"
    case .connected(.moving(.external(let direction))): "Moving \(word(direction)) (panel)"
    case .connected(.moving): "Moving"
    }
  }

  static func message(for error: any Error) -> String {
    switch error {
    case let error as DeskControllerError: message(for: error)
    case let error as PositionError: message(for: error)
    default: error.localizedDescription
    }
  }

  static func message(for error: DeskControllerError) -> String {
    switch error {
    case .notConnected: "The desk is not connected"
    case .outOfRange: "That height is out of range"
    case .interrupted: "Interrupted"
    case .deskMoving: "The desk is moving. Try again when it stops"
    case .moveFailed(.didNotStart): "The desk did not start moving"
    case .moveFailed(.stalled): "The desk stopped before the target. Is something in the way?"
    case .moveFailed(.timedOut): "The move timed out"
    case .moveFailed(.holdTimeLimit): "Stopped: a hold is limited to 20 seconds"
    case .moveFailed(.transport(let detail)): "Bluetooth error: \(detail)"
    case .positions(let error): message(for: error)
    }
  }

  static func message(for error: PositionError) -> String {
    switch error {
    case .invalidName(.empty): "Enter a name"
    case .invalidName(.numeric): "A name can't be a number"
    case .invalidName(.numericSlug): "A name can't turn into a number"
    case .duplicateName(let clashing): "Clashes with \"\(clashing)\": same name or slug"
    case .unknownPosition: "That position no longer exists"
    case .readOnly: "The positions file is read-only"
    case .saveFailed(let detail): "Could not save: \(detail)"
    }
  }

  static func message(for warning: PositionStoreWarning) -> String {
    switch warning {
    case .corruptFileMovedAside(let url):
      "The positions file was unreadable and was moved to \(url.lastPathComponent)"
    case .corruptFileLeftInPlace:
      "The positions file can't be read. Positions are read-only"
    case .invalidContent:
      "The positions file has invalid entries. Positions are read-only until it is fixed"
    case .unsupportedVersion(let version):
      "The positions file is version \(version), from a newer Idasen. Positions are read-only"
    }
  }

  private static func word(_ direction: MoveDirection) -> String {
    direction == .up ? "up" : "down"
  }
}

extension CBManagerAuthorization {
  var label: String {
    switch self {
    case .notDetermined: "not asked yet"
    case .restricted: "restricted"
    case .denied: "denied"
    case .allowedAlways: "allowed"
    @unknown default: "unknown"
    }
  }
}
