import XCTest

@testable import DeskKit

final class DiscoveryPlanTests: XCTestCase {
  private let remembered = UUID()

  func testDeskConnectedAtSystemLevelIsUsedBeforeAnythingElse() {
    var plan = DiscoveryPlan()
    let connected = UUID()
    let actions = plan.start(
      remembered: remembered, connectedAtSystemLevel: connected, rememberedKnownToSystem: true)
    XCTAssertEqual(actions.first, .connect(connected))
    XCTAssertFalse(actions.contains { if case .scan = $0 { true } else { false } })
  }

  func testRememberedDeskGetsPendingConnectWithoutScan() {
    var plan = DiscoveryPlan()
    let actions = plan.start(
      remembered: remembered, connectedAtSystemLevel: nil, rememberedKnownToSystem: true)
    XCTAssertEqual(actions, [.connect(remembered), .scheduleNotFoundHint(.seconds(15))])
    XCTAssertEqual(plan.stage, .pendingConnect)
    XCTAssertTrue(plan.isSearching)
  }

  func testNoRememberedDeskScansByServiceThenFallsBackToName() {
    var plan = DiscoveryPlan()
    let actions = plan.start(
      remembered: nil, connectedAtSystemLevel: nil, rememberedKnownToSystem: false)
    XCTAssertEqual(
      actions,
      [.scan(.service), .scheduleNameFallback(.seconds(5)), .scheduleNotFoundHint(.seconds(15))])
    XCTAssertEqual(plan.stage, .scanning(.service))
    XCTAssertEqual(plan.nameFallbackFired(), [.scan(.namePrefix)])
    XCTAssertEqual(plan.stage, .scanning(.namePrefix))
    XCTAssertEqual(plan.nameFallbackFired(), [])
  }

  func testRememberedDeskUnknownToSystemScans() {
    var plan = DiscoveryPlan()
    let actions = plan.start(
      remembered: remembered, connectedAtSystemLevel: nil, rememberedKnownToSystem: false)
    XCTAssertEqual(actions.first, .scan(.service))
  }

  func testFallbackIsIgnoredOnceAttachedOrStopped() {
    var plan = DiscoveryPlan()
    _ = plan.start(remembered: nil, connectedAtSystemLevel: nil, rememberedKnownToSystem: false)
    XCTAssertEqual(plan.attached(), [.stopScan, .cancelTimers, .setHint(false)])
    XCTAssertEqual(plan.nameFallbackFired(), [])
    XCTAssertFalse(plan.isSearching)

    _ = plan.start(remembered: nil, connectedAtSystemLevel: nil, rememberedKnownToSystem: false)
    XCTAssertEqual(plan.stop(), [.stopScan, .cancelTimers, .setHint(false)])
    XCTAssertEqual(plan.nameFallbackFired(), [])
  }

  func testHintOnlyWhileSearching() {
    var plan = DiscoveryPlan()
    XCTAssertEqual(plan.notFoundHintFired(), [])
    _ = plan.start(
      remembered: remembered, connectedAtSystemLevel: nil, rememberedKnownToSystem: true)
    XCTAssertEqual(plan.notFoundHintFired(), [.setHint(true)])
    XCTAssertEqual(plan.attached(), [.cancelTimers, .setHint(false)])
    XCTAssertEqual(plan.notFoundHintFired(), [])
  }

  func testPickedDeskStopsScanAndRearmsHint() {
    var plan = DiscoveryPlan()
    let picked = UUID()
    _ = plan.start(remembered: nil, connectedAtSystemLevel: nil, rememberedKnownToSystem: false)
    XCTAssertEqual(
      plan.connectPicked(picked, hintDelay: .seconds(9)),
      [.stopScan, .cancelTimers, .connect(picked), .scheduleNotFoundHint(.seconds(9))])
    XCTAssertEqual(plan.stage, .pendingConnect)
    XCTAssertEqual(plan.notFoundHintFired(), [.setHint(true)])
  }

  func testStartHonoursRemainingHintDelay() {
    var plan = DiscoveryPlan()
    let actions = plan.start(
      remembered: remembered, connectedAtSystemLevel: nil, rememberedKnownToSystem: true,
      hintDelay: .seconds(3))
    XCTAssertEqual(actions, [.connect(remembered), .scheduleNotFoundHint(.seconds(3))])
  }

  func testNamePrefixFilter() {
    XCTAssertTrue(DiscoveryPlan.isDeskName("Desk 1234"))
    XCTAssertFalse(DiscoveryPlan.isDeskName("desk"))
    XCTAssertFalse(DiscoveryPlan.isDeskName("My Desk"))
    XCTAssertFalse(DiscoveryPlan.isDeskName(nil))
  }

  func testDiscoveredListSortsBySignalAndThrottlesRSSIJitter() {
    var list = DiscoveredDeskList()
    let near = UUID()
    let far = UUID()
    XCTAssertTrue(list.update(id: far, name: "Desk B", rssi: -80))
    XCTAssertTrue(list.update(id: near, name: "Desk A", rssi: -50))
    XCTAssertEqual(list.desks.map(\.id), [near, far])

    XCTAssertFalse(list.update(id: near, name: "Desk A", rssi: -52))
    XCTAssertTrue(list.update(id: near, name: "Desk A", rssi: -60))
    XCTAssertTrue(list.update(id: near, name: "Desk Renamed", rssi: -60))
    XCTAssertEqual(list.desks.first?.name, "Desk Renamed")
    XCTAssertTrue(list.update(id: far, name: "Desk B", rssi: -40))
    XCTAssertEqual(list.desks.map(\.id), [far, near])

    XCTAssertTrue(list.removeAll())
    XCTAssertFalse(list.removeAll())
    XCTAssertTrue(list.desks.isEmpty)
  }
}
