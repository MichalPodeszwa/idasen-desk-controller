import XCTest

@testable import DeskKit

@MainActor
final class DeskSettingsTests: XCTestCase {
  func testUserDefaultsSettingsRoundTripAndClear() throws {
    let suite = "DeskSettingsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = UserDefaultsDeskSettings(defaults: defaults)
    XCTAssertNil(settings.rememberedPeripheral)

    let id = UUID()
    settings.rememberedPeripheral = id
    XCTAssertEqual(UserDefaultsDeskSettings(defaults: defaults).rememberedPeripheral, id)

    settings.rememberedPeripheral = nil
    XCTAssertNil(settings.rememberedPeripheral)
  }

  func testGarbageValueReadsAsNil() throws {
    let suite = "DeskSettingsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("not a uuid", forKey: UserDefaultsDeskSettings.rememberedPeripheralKey)
    XCTAssertNil(UserDefaultsDeskSettings(defaults: defaults).rememberedPeripheral)
  }

  func testCoreBluetoothTransportStartsWithoutTouchingBluetooth() {
    let transport = CoreBluetoothTransport(settings: InMemoryDeskSettings())
    XCTAssertTrue([.disconnected, .unauthorized].contains(transport.connectionState))
    XCTAssertFalse(transport.canSendWriteWithoutResponse)
    XCTAssertTrue(transport.discoveredDesks.isEmpty)
    transport.connect()
    XCTAssertTrue([.disconnected, .unauthorized].contains(transport.connectionState))
  }

  func testReadAndWriteWithoutConnectionThrowNotConnected() async {
    let transport = CoreBluetoothTransport(settings: InMemoryDeskSettings())
    do {
      _ = try await transport.readHeight()
      XCTFail("expected notConnected")
    } catch {
      XCTAssertEqual(error as? DeskTransportError, .notConnected)
    }
    do {
      try await transport.write(Data([0xFF, 0x00]), to: .control, type: .withResponse)
      XCTFail("expected notConnected")
    } catch {
      XCTAssertEqual(error as? DeskTransportError, .notConnected)
    }
  }
}
