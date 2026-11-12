import CoreBluetooth
import XCTest

@testable import DeskKit

final class TransportErrorMappingTests: XCTestCase {
  private func att(_ code: CBATTError.Code) -> NSError {
    NSError(domain: CBATTError.errorDomain, code: code.rawValue)
  }

  private func cb(_ code: CBError.Code) -> NSError {
    NSError(domain: CBError.errorDomain, code: code.rawValue)
  }

  func testInsufficientAuthenticationAndEncryptionMeanPairingMode() {
    for code in [CBATTError.Code.insufficientAuthentication, .insufficientEncryption] {
      XCTAssertEqual(
        TransportErrorMapping.classifySetupFailure(att(code)),
        .pairingRequired(.pairingModeNeeded))
    }
  }

  func testRemovedPairingInformationMeansBondRemoved() {
    XCTAssertEqual(
      TransportErrorMapping.classifySetupFailure(cb(.peerRemovedPairingInformation)),
      .pairingRequired(.bondRemovedByDesk))
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        cb(.peerRemovedPairingInformation), setupComplete: true, sinceConnect: .seconds(60),
        wasSetUpBefore: true),
      .pairingRequired(.bondRemovedByDesk))
    XCTAssertEqual(
      TransportErrorMapping.classifyConnectFailure(cb(.peerRemovedPairingInformation)),
      .pairingRequired(.bondRemovedByDesk))
  }

  func testTimeoutAndConnectionFailedRetry() {
    for code in [CBError.Code.connectionTimeout, .connectionFailed] {
      XCTAssertEqual(TransportErrorMapping.classifySetupFailure(cb(code)), .retry)
      XCTAssertEqual(TransportErrorMapping.classifyConnectFailure(cb(code)), .retry)
      XCTAssertEqual(
        TransportErrorMapping.classifyDisconnect(
          cb(code), setupComplete: true, sinceConnect: .seconds(60), wasSetUpBefore: true),
        .retry)
    }
    XCTAssertEqual(TransportErrorMapping.classifyConnectFailure(nil), .retry)
  }

  func testUnknownSetupErrorsRetryInsteadOfFailingPermanently() {
    let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    XCTAssertEqual(TransportErrorMapping.classifySetupFailure(error), .retry)
    XCTAssertEqual(TransportErrorMapping.classifySetupFailure(att(.invalidHandle)), .retry)
  }

  func testEarlyDisconnectBeforeSetupIsPairingHeuristic() {
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        nil, setupComplete: false, sinceConnect: .seconds(2), wasSetUpBefore: false),
      .pairingRequired(.pairingModeNeeded))
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        cb(.peripheralDisconnected), setupComplete: false, sinceConnect: .seconds(5),
        wasSetUpBefore: false),
      .pairingRequired(.pairingModeNeeded))
  }

  func testEarlyDisconnectOfAlreadyBondedDeskKeepsReconnecting() {
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        nil, setupComplete: false, sinceConnect: .seconds(2), wasSetUpBefore: true),
      .reconnect)
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        cb(.peripheralDisconnected), setupComplete: false, sinceConnect: .seconds(1),
        wasSetUpBefore: true),
      .reconnect)
  }

  func testAuthErrorsStillMeanPairingForBondedDesk() {
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        att(.insufficientAuthentication), setupComplete: false, sinceConnect: .seconds(1),
        wasSetUpBefore: true),
      .pairingRequired(.pairingModeNeeded))
  }

  func testLateOrCompletedDisconnectsReconnect() {
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        nil, setupComplete: false, sinceConnect: .seconds(6), wasSetUpBefore: false),
      .reconnect)
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        nil, setupComplete: true, sinceConnect: .seconds(1), wasSetUpBefore: false),
      .reconnect)
    XCTAssertEqual(
      TransportErrorMapping.classifyDisconnect(
        cb(.connectionTimeout), setupComplete: true, sinceConnect: .seconds(400),
        wasSetUpBefore: false),
      .retry)
  }

  func testBackoffGrowsAndCapsThenResets() {
    var backoff = ReconnectBackoff()
    let delays = (0..<7).map { _ in backoff.nextDelay() }
    XCTAssertEqual(
      delays,
      [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15),
        .seconds(15),
      ])
    backoff.reset()
    XCTAssertEqual(backoff.nextDelay(), .seconds(1))
  }
}
