import Foundation

enum GattCharacteristic: CaseIterable, Hashable {
  case control
  case referenceInput
  case referenceOutput
  case dpg

  var uuid: String {
    switch self {
    case .control: DeskUUID.control
    case .referenceInput: DeskUUID.referenceInput
    case .referenceOutput: DeskUUID.referenceOutput
    case .dpg: DeskUUID.dpg
    }
  }

  var service: String {
    switch self {
    case .control: DeskUUID.controlService
    case .referenceInput: DeskUUID.referenceInputService
    case .referenceOutput: DeskUUID.referenceOutputService
    case .dpg: DeskUUID.dpgService
    }
  }

  var requiredProperties: GattProperties {
    switch self {
    case .control, .referenceInput: [.write, .writeWithoutResponse]
    case .referenceOutput: [.read, .notify]
    case .dpg: [.write, .notify]
    }
  }

  var label: String {
    switch self {
    case .control: "control"
    case .referenceInput: "reference input"
    case .referenceOutput: "reference output"
    case .dpg: "DPG"
    }
  }

  static var serviceUUIDs: [String] {
    allCases.map(\.service)
  }
}

struct GattProperties: OptionSet, Hashable {
  let rawValue: UInt

  static let read = GattProperties(rawValue: 0x02)
  static let writeWithoutResponse = GattProperties(rawValue: 0x04)
  static let write = GattProperties(rawValue: 0x08)
  static let notify = GattProperties(rawValue: 0x10)
}

struct SetupSequence {
  enum Step: Equatable {
    case idle
    case discoveringServices
    case discoveringCharacteristics
    case enablingNotify(GattCharacteristic)
    case awaitingBaseOffset
    case awaitingUserID
    case writingUserID
    case finished
    case failed
  }

  enum Command: Equatable {
    case discoverServices
    case discoverCharacteristics
    case enableNotify(GattCharacteristic)
    case writeDPG(Data, expectsResponse: Bool)
    case finish(baseOffsetMM: Double?)
    case fail(String)
  }

  private static let notifyOrder: [GattCharacteristic] = [.referenceOutput, .dpg]

  let patchesUserID: Bool
  private(set) var step = Step.idle
  private(set) var baseOffsetMM: Double?

  init(patchesUserID: Bool = false) {
    self.patchesUserID = patchesUserID
  }

  var isWaitingForDPGResponse: Bool {
    step == .awaitingBaseOffset || step == .awaitingUserID
  }

  mutating func start() -> Command {
    step = .discoveringServices
    return .discoverServices
  }

  mutating func servicesDiscovered() -> Command {
    step = .discoveringCharacteristics
    return .discoverCharacteristics
  }

  mutating func characteristicsDiscovered(_ found: [GattCharacteristic: GattProperties]) -> Command
  {
    for characteristic in GattCharacteristic.allCases {
      guard let properties = found[characteristic] else {
        return failed("The desk is missing the \(characteristic.label) characteristic")
      }
      guard properties.isSuperset(of: characteristic.requiredProperties) else {
        return failed(
          "The desk's \(characteristic.label) characteristic doesn't have the expected properties")
      }
    }
    step = .enablingNotify(Self.notifyOrder[0])
    return .enableNotify(Self.notifyOrder[0])
  }

  mutating func notifyEnabled() -> Command {
    guard case .enablingNotify(let current) = step,
      let index = Self.notifyOrder.firstIndex(of: current)
    else { return .fail("Unexpected notify confirmation") }
    if index + 1 < Self.notifyOrder.count {
      step = .enablingNotify(Self.notifyOrder[index + 1])
      return .enableNotify(Self.notifyOrder[index + 1])
    }
    step = .awaitingBaseOffset
    return .writeDPG(DPG.readFrame(.baseOffset), expectsResponse: true)
  }

  mutating func dpgResponse(_ data: Data) -> Command? {
    switch step {
    case .awaitingBaseOffset:
      baseOffsetMM = DPG.parseBaseOffsetMM(data)
      return afterBaseOffset()
    case .awaitingUserID:
      if let patch = DPG.userIDPatchFrame(response: data) {
        step = .writingUserID
        return .writeDPG(patch, expectsResponse: false)
      }
      return finish()
    default:
      return nil
    }
  }

  mutating func dpgUnavailable() -> Command? {
    switch step {
    case .awaitingBaseOffset:
      baseOffsetMM = nil
      return afterBaseOffset()
    case .awaitingUserID, .writingUserID:
      return finish()
    default:
      return nil
    }
  }

  mutating func writeCompleted() -> Command? {
    step == .writingUserID ? finish() : nil
  }

  private mutating func afterBaseOffset() -> Command {
    guard patchesUserID else { return finish() }
    step = .awaitingUserID
    return .writeDPG(DPG.readFrame(.userID), expectsResponse: true)
  }

  private mutating func finish() -> Command {
    step = .finished
    return .finish(baseOffsetMM: baseOffsetMM)
  }

  private mutating func failed(_ message: String) -> Command {
    step = .failed
    return .fail(message)
  }
}
