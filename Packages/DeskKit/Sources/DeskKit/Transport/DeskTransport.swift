import Foundation

public enum DeskCharacteristic: Sendable {
  case control
  case referenceInput
  case dpg
}

public enum DeskWriteType: Sendable {
  case withResponse
  case withoutResponse
}

public enum PairingReason: Equatable, Sendable {
  case pairingModeNeeded
  case bondRemovedByDesk
}

public enum TransportConnectionState: Equatable, Sendable {
  case poweredOff
  case unauthorized
  case disconnected
  case scanning
  case connecting
  case pairingRequired(PairingReason)
  case failed(String)
  case connected
}

public struct DiscoveredDesk: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var rssi: Int

  public init(id: UUID, name: String, rssi: Int) {
    self.id = id
    self.name = name
    self.rssi = rssi
  }
}

public enum DeskTransportEvent: Equatable, Sendable {
  case connectionState(TransportConnectionState)
  case sample(HeightSample)
  case discoveredDesks([DiscoveredDesk])
  case baseOffset(Double?)
  case notFoundHint(Bool)
}

public enum DeskTransportError: Error, Equatable, Sendable {
  case notConnected
  case readFailed(String)
  case writeFailed(String)
}

@MainActor
public protocol DeskTransport: AnyObject {
  var connectionState: TransportConnectionState { get }
  var discoveredDesks: [DiscoveredDesk] { get }
  var baseOffsetMM: Double? { get }
  var notFoundHint: Bool { get }
  var canSendWriteWithoutResponse: Bool { get }
  var events: AsyncStream<DeskTransportEvent> { get }

  func readHeight() async throws -> HeightSample
  func write(_ data: Data, to characteristic: DeskCharacteristic, type: DeskWriteType) async throws

  func connect()
  func connect(to desk: DiscoveredDesk.ID)
  func disconnect()
  func forget()
}

extension DeskTransport {
  public var notFoundHint: Bool { false }
}
