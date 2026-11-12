import AppKit
import XCTest

@testable import DeskKit

@MainActor
final class AppLifecycleTests: XCTestCase {
  private let center = NotificationCenter()
  private let workspace = NotificationCenter()
  private let distributed = NotificationCenter()
  private var endHolds = 0
  private var sleeps = 0
  private var wakes = 0
  private var lifecycle: AppLifecycle!

  override func setUp() async throws {
    lifecycle = AppLifecycle(
      center: center, workspaceCenter: workspace, distributedCenter: distributed,
      endHold: { self.endHolds += 1 },
      prepareForSleep: { self.sleeps += 1 },
      handleWake: { self.wakes += 1 })
  }

  override func tearDown() async throws {
    lifecycle.invalidate()
  }

  private func settle() async {
    let expectation = expectation(description: "main queue drained")
    DispatchQueue.main.async { expectation.fulfill() }
    await fulfillment(of: [expectation], timeout: 2)
  }

  private func assertEndsHold(
    _ name: Notification.Name, on target: NotificationCenter, file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let before = endHolds
    target.post(name: name, object: nil)
    await settle()
    XCTAssertEqual(
      endHolds, before + 1, "\(name.rawValue) must end the hold", file: file, line: line)
    XCTAssertEqual(sleeps, 0, file: file, line: line)
    XCTAssertEqual(wakes, 0, file: file, line: line)
  }

  func testWindowResignKeyAndCloseEndHold() async {
    await assertEndsHold(NSWindow.didResignKeyNotification, on: center)
    await assertEndsHold(NSWindow.willCloseNotification, on: center)
  }

  func testAppResignActiveEndsHold() async {
    await assertEndsHold(NSApplication.didResignActiveNotification, on: center)
  }

  func testSessionResignAndScreensSleepEndHold() async {
    await assertEndsHold(NSWorkspace.sessionDidResignActiveNotification, on: workspace)
    await assertEndsHold(NSWorkspace.screensDidSleepNotification, on: workspace)
  }

  func testScreenLockEndsHold() async {
    XCTAssertEqual(AppLifecycle.screenLockedNotification.rawValue, "com.apple.screenIsLocked")
    await assertEndsHold(AppLifecycle.screenLockedNotification, on: distributed)
  }

  func testSleepAndWake() async {
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    await settle()
    XCTAssertEqual(sleeps, 1)
    XCTAssertEqual(wakes, 0)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    await settle()
    XCTAssertEqual(wakes, 1)
    XCTAssertEqual(sleeps, 1)
    XCTAssertEqual(endHolds, 0)
  }

  func testNotificationsOnTheWrongCenterAreIgnored() async {
    center.post(name: AppLifecycle.screenLockedNotification, object: nil)
    distributed.post(name: NSApplication.didResignActiveNotification, object: nil)
    await settle()
    XCTAssertEqual(endHolds, 0)
  }

  func testInvalidateStopsDelivery() async {
    lifecycle.invalidate()
    center.post(name: NSApplication.didResignActiveNotification, object: nil)
    await settle()
    XCTAssertEqual(endHolds, 0)
  }
}
