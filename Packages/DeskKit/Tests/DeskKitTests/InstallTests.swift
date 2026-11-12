import XCTest

@testable import DeskKit

final class InstallTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "InstallTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  func testOnlyApplicationsIsAcceptable() {
    XCTAssertTrue(
      InstallLocation.isAcceptable(bundleURL: URL(filePath: "/Applications/Idasen.app")))
    XCTAssertFalse(
      InstallLocation.isAcceptable(bundleURL: URL(filePath: "/Users/me/Downloads/Idasen.app")))
    XCTAssertFalse(
      InstallLocation.isAcceptable(bundleURL: URL(filePath: "/Users/me/Applications/Idasen.app")))
    XCTAssertFalse(
      InstallLocation.isAcceptable(
        bundleURL: URL(filePath: "/Applications/AppTranslocation/ABC/d/Idasen.app")))
    XCTAssertFalse(
      InstallLocation.isAcceptable(
        bundleURL: URL(
          filePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Idasen.app")))
    XCTAssertEqual(
      InstallLocation.refusal(bundleURL: URL(filePath: "/tmp/Idasen.app")),
      "Move Idasen to Applications")
    XCTAssertNil(InstallLocation.refusal(bundleURL: URL(filePath: "/Applications/Idasen.app")))
  }

  func testInstallCreatesSymlinkAndIsIdempotent() throws {
    let helper = URL(filePath: "/Applications/Idasen.app/Contents/Helpers/idasen")
    let installer = CLIInstaller(helperURL: helper, directory: directory.appending(path: "bin"))
    XCTAssertEqual(installer.status(), .notInstalled)
    try installer.install()
    XCTAssertEqual(installer.status(), .installed)
    try installer.install()
    XCTAssertEqual(installer.status(), .installed)
    try installer.uninstall()
    XCTAssertEqual(installer.status(), .notInstalled)
  }

  func testInstallReplacesLinkToOtherCopy() throws {
    let old = CLIInstaller(helperURL: URL(filePath: "/old/idasen"), directory: directory)
    try old.install()
    let installer = CLIInstaller(helperURL: URL(filePath: "/new/idasen"), directory: directory)
    XCTAssertEqual(installer.status(), .pointsElsewhere("/old/idasen"))
    try installer.install()
    XCTAssertEqual(installer.status(), .installed)
  }

  func testInstallNeverOverwritesARegularFile() throws {
    let installer = CLIInstaller(helperURL: URL(filePath: "/new/idasen"), directory: directory)
    try Data("#!/bin/sh".utf8).write(to: installer.linkURL)
    XCTAssertEqual(installer.status(), .blockedByFile)
    XCTAssertThrowsError(try installer.install())
    XCTAssertThrowsError(try installer.uninstall())
    XCTAssertEqual(try String(contentsOf: installer.linkURL, encoding: .utf8), "#!/bin/sh")
  }

  func testPathDetection() {
    let installer = CLIInstaller(
      helperURL: URL(filePath: "/x/idasen"), directory: URL(filePath: "/Users/me/.local/bin"))
    XCTAssertTrue(installer.isOnPath("/usr/bin:/Users/me/.local/bin:/bin"))
    XCTAssertTrue(installer.isOnPath("/Users/me/.local/bin/"))
    XCTAssertFalse(installer.isOnPath("/usr/bin:/bin"))
    XCTAssertFalse(installer.isOnPath(nil))
  }
}
