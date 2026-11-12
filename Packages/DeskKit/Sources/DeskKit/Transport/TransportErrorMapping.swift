import CoreBluetooth
import Foundation

enum LinkFailure: Equatable {
  case pairingRequired(PairingReason)
  case retry
  case reconnect
  case fail(String)
}

enum TransportErrorMapping {
  static let earlyDisconnectWindow = Duration.seconds(5)

  static func classifySetupFailure(_ error: any Error) -> LinkFailure {
    if let pairing = pairingReason(for: error) { return .pairingRequired(pairing) }
    return .retry
  }

  static func classifyConnectFailure(_ error: (any Error)?) -> LinkFailure {
    guard let error else { return .retry }
    if let pairing = pairingReason(for: error) { return .pairingRequired(pairing) }
    return .retry
  }

  static func classifyDisconnect(
    _ error: (any Error)?, setupComplete: Bool, sinceConnect: Duration, wasSetUpBefore: Bool
  ) -> LinkFailure {
    if let error, let pairing = pairingReason(for: error) { return .pairingRequired(pairing) }
    if let error, isConnectionFailure(error) { return .retry }
    if !setupComplete, !wasSetUpBefore, sinceConnect <= earlyDisconnectWindow {
      return .pairingRequired(.pairingModeNeeded)
    }
    return .reconnect
  }

  static func pairingReason(for error: any Error) -> PairingReason? {
    let nsError = error as NSError
    if nsError.domain == CBATTError.errorDomain {
      let code = CBATTError.Code(rawValue: nsError.code)
      if code == .insufficientAuthentication || code == .insufficientEncryption {
        return .pairingModeNeeded
      }
    } else if nsError.domain == CBError.errorDomain {
      if CBError.Code(rawValue: nsError.code) == .peerRemovedPairingInformation {
        return .bondRemovedByDesk
      }
    }
    return nil
  }

  static func isConnectionFailure(_ error: any Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == CBError.errorDomain else { return false }
    switch CBError.Code(rawValue: nsError.code) {
    case .connectionTimeout, .connectionFailed: return true
    default: return false
    }
  }
}

struct ReconnectBackoff: Equatable {
  static let delays: [Duration] = [
    .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15),
  ]

  private(set) var attempt = 0

  mutating func nextDelay() -> Duration {
    let delay = Self.delays[min(attempt, Self.delays.count - 1)]
    attempt += 1
    return delay
  }

  mutating func reset() {
    attempt = 0
  }
}
