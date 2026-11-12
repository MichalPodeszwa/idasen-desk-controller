import XCTest

@testable import DeskKit

final class LoginShellPathTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "LoginShellPathTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  private func script(_ body: String) throws -> String {
    let url = directory.appending(path: "shell-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }

  func testExtractIgnoresNoiseBeforeTheMarker() {
    XCTAssertEqual(
      LoginShellPath.extract(from: "welcome\n__IDASEN_PATH__/a:/b\n"), "/a:/b")
    XCTAssertNil(LoginShellPath.extract(from: "no marker"))
    XCTAssertNil(LoginShellPath.extract(from: "__IDASEN_PATH__"))
  }

  func testResolvesPathFromARealShell() async throws {
    let path = await LoginShellPath.resolve(shell: "/bin/sh", timeout: .seconds(5))
    XCTAssertNotNil(path)
    XCTAssertTrue(path?.contains("/") ?? false)
  }

  func testResolvesPathFromAFakeShellWithNoise() async throws {
    let shell = try script("echo 'motd noise'\nprintf '%s%s' '__IDASEN_PATH__' '/x/bin:/y/bin'")
    let path = await LoginShellPath.resolve(shell: shell, timeout: .seconds(5))
    XCTAssertEqual(path, "/x/bin:/y/bin")
  }

  func testSlowShellTimesOut() async throws {
    let shell = try script("sleep 30")
    let started = ContinuousClock.now
    let path = await LoginShellPath.resolve(shell: shell, timeout: .milliseconds(300))
    XCTAssertNil(path)
    XCTAssertLessThan(started.duration(to: .now), .seconds(5))
  }

  func testMissingOrFailingShellGivesNil() async throws {
    let missing = await LoginShellPath.resolve(shell: "/nonexistent/shell")
    XCTAssertNil(missing)
    let noShell = await LoginShellPath.resolve(shell: nil)
    XCTAssertNil(noShell)
    let failing = try script("exit 3")
    let failed = await LoginShellPath.resolve(shell: failing, timeout: .seconds(5))
    XCTAssertNil(failed)
  }
}
