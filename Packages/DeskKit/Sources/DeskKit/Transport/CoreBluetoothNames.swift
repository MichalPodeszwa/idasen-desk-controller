import CoreBluetooth
import Foundation

enum CoreBluetoothNames {
  static func state(_ state: CBManagerState) -> String {
    switch state {
    case .unknown: "unknown"
    case .resetting: "resetting"
    case .unsupported: "unsupported"
    case .unauthorized: "unauthorized"
    case .poweredOff: "poweredOff"
    case .poweredOn: "poweredOn"
    @unknown default: "state(\(state.rawValue))"
    }
  }

  static func authorization(_ authorization: CBManagerAuthorization) -> String {
    switch authorization {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .allowedAlways: "allowedAlways"
    @unknown default: "authorization(\(authorization.rawValue))"
    }
  }

  static func properties(_ properties: CBCharacteristicProperties) -> String {
    let names: [(CBCharacteristicProperties, String)] = [
      (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "writeWithoutResponse"),
      (.write, "write"), (.notify, "notify"), (.indicate, "indicate"),
      (.authenticatedSignedWrites, "signedWrites"), (.extendedProperties, "extended"),
      (.notifyEncryptionRequired, "notifyEncryptionRequired"),
      (.indicateEncryptionRequired, "indicateEncryptionRequired"),
    ]
    let present = names.filter { properties.contains($0.0) }.map(\.1)
    let hex = String(format: "0x%02X", properties.rawValue)
    return "\(hex) [\(present.joined(separator: ", "))]"
  }

  static func error(_ error: any Error) -> String {
    let nsError = error as NSError
    var name: String?
    if nsError.domain == CBError.errorDomain {
      name = cbErrorName(CBError.Code(rawValue: nsError.code))
    } else if nsError.domain == CBATTError.errorDomain {
      name = attErrorName(CBATTError.Code(rawValue: nsError.code))
    }
    let label = name.map { " \($0)" } ?? ""
    return "\(nsError.domain)#\(nsError.code)\(label) \"\(nsError.localizedDescription)\""
  }

  static func error(_ error: (any Error)?) -> String {
    error.map { Self.error($0) } ?? "none"
  }

  private static func cbErrorName(_ code: CBError.Code?) -> String? {
    switch code {
    case .unknown: "unknown"
    case .invalidParameters: "invalidParameters"
    case .invalidHandle: "invalidHandle"
    case .notConnected: "notConnected"
    case .outOfSpace: "outOfSpace"
    case .operationCancelled: "operationCancelled"
    case .connectionTimeout: "connectionTimeout"
    case .peripheralDisconnected: "peripheralDisconnected"
    case .uuidNotAllowed: "uuidNotAllowed"
    case .alreadyAdvertising: "alreadyAdvertising"
    case .connectionFailed: "connectionFailed"
    case .connectionLimitReached: "connectionLimitReached"
    case .unknownDevice: "unknownDevice"
    case .operationNotSupported: "operationNotSupported"
    case .peerRemovedPairingInformation: "peerRemovedPairingInformation"
    case .encryptionTimedOut: "encryptionTimedOut"
    case .tooManyLEPairedDevices: "tooManyLEPairedDevices"
    default: nil
    }
  }

  private static func attErrorName(_ code: CBATTError.Code?) -> String? {
    switch code {
    case .invalidHandle: "invalidHandle"
    case .readNotPermitted: "readNotPermitted"
    case .writeNotPermitted: "writeNotPermitted"
    case .invalidPdu: "invalidPdu"
    case .insufficientAuthentication: "insufficientAuthentication"
    case .requestNotSupported: "requestNotSupported"
    case .invalidOffset: "invalidOffset"
    case .insufficientAuthorization: "insufficientAuthorization"
    case .prepareQueueFull: "prepareQueueFull"
    case .attributeNotFound: "attributeNotFound"
    case .attributeNotLong: "attributeNotLong"
    case .insufficientEncryptionKeySize: "insufficientEncryptionKeySize"
    case .invalidAttributeValueLength: "invalidAttributeValueLength"
    case .unlikelyError: "unlikelyError"
    case .insufficientEncryption: "insufficientEncryption"
    case .unsupportedGroupType: "unsupportedGroupType"
    case .insufficientResources: "insufficientResources"
    case .success: "success"
    default: nil
    }
  }
}
