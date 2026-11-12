import XCTest

@testable import DeskKit

@MainActor
final class PositionStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "PositionStoreTests-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var fileURL: URL { directory.appending(path: "positions.json") }

  private func makeStore() -> PositionStore {
    PositionStore(directory: directory, now: { Date(timeIntervalSince1970: 1_800_000_000) })
  }

  private func height(_ raw: Int) -> DeskHeight {
    DeskHeight(clamping: raw)
  }

  private func writeRaw(_ text: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try text.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  private func directoryContents() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  func testStartsEmptyWithoutFile() {
    let store = makeStore()
    XCTAssertTrue(store.positions.isEmpty)
    XCTAssertNil(store.warning)
    XCTAssertFalse(store.isReadOnly)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testAddKeepsOrderAndReturnsPosition() throws {
    let store = makeStore()
    let sit = try store.add(name: "Sit", height: height(1050))
    try store.add(name: "Stand", height: height(5000))
    XCTAssertEqual(store.positions.map(\.name), ["Sit", "Stand"])
    XCTAssertEqual(sit.height.raw, 1050)
    XCTAssertEqual(store.position(id: sit.id), sit)
  }

  func testAddNormalizesName() throws {
    let store = makeStore()
    let position = try store.add(name: "  Cafe\u{301}  ", height: height(100))
    XCTAssertEqual(Array(position.name.unicodeScalars), Array("Caf\u{E9}".unicodeScalars))
  }

  func testAddRejectsInvalidNames() {
    let store = makeStore()
    XCTAssertThrowsError(try store.add(name: "  ", height: height(1))) {
      XCTAssertEqual($0 as? PositionError, .invalidName(.empty))
    }
    XCTAssertThrowsError(try store.add(name: "100", height: height(1))) {
      XCTAssertEqual($0 as? PositionError, .invalidName(.numeric))
    }
    XCTAssertThrowsError(try store.add(name: "100.5", height: height(1))) {
      XCTAssertEqual($0 as? PositionError, .invalidName(.numeric))
    }
    XCTAssertTrue(store.positions.isEmpty)
  }

  func testAddRejectsDuplicatesIgnoringCaseAndNormalization() throws {
    let store = makeStore()
    try store.add(name: "ŁÓŻKO", height: height(1))
    try store.add(name: "Café", height: height(2))
    for (name, clash) in [
      ("łóżko", "ŁÓŻKO"), (" ŁÓŻKO ", "ŁÓŻKO"), ("Cafe\u{301}", "Café"), ("CAFÉ", "Café"),
    ] {
      XCTAssertThrowsError(try store.add(name: name, height: height(3)), name) {
        XCTAssertEqual($0 as? PositionError, .duplicateName(clashingWith: clash))
      }
    }
    XCTAssertEqual(store.positions.count, 2)
  }

  func testAddRejectsSlugCollisions() throws {
    let store = makeStore()
    try store.add(name: "Żółte biurko", height: height(1))
    for name in [
      "Zolte Biurko", "zolte-biurko", "  ŻÓŁTE  biurko!", "Żółte\u{00A0}biurko",
    ] {
      XCTAssertThrowsError(try store.add(name: name, height: height(2)), name) {
        XCTAssertEqual($0 as? PositionError, .duplicateName(clashingWith: "Żółte biurko"))
      }
    }
    XCTAssertEqual(store.positions.count, 1)
  }

  func testRenameRejectsSlugCollisions() throws {
    let store = makeStore()
    let sit = try store.add(name: "Sit", height: height(1))
    try store.add(name: "Standing", height: height(2))
    XCTAssertThrowsError(try store.rename(id: sit.id, to: "STANDING!")) {
      XCTAssertEqual($0 as? PositionError, .duplicateName(clashingWith: "Standing"))
    }
    try store.rename(id: sit.id, to: "Sit-down")
    try store.rename(id: sit.id, to: "Sit down")
    XCTAssertEqual(store.position(id: sit.id)?.name, "Sit down")
  }

  func testEmptySlugsDoNotCollide() throws {
    let store = makeStore()
    try store.add(name: "🙂", height: height(1))
    try store.add(name: "🙃", height: height(2))
    XCTAssertEqual(store.positions.map(\.slug), ["", ""])
    XCTAssertNil(store.position(matching: ""))
  }

  func testNumericSlugIsRejected() throws {
    let store = makeStore()
    XCTAssertThrowsError(try store.add(name: "１２３", height: height(1))) {
      XCTAssertEqual($0 as? PositionError, .invalidName(.numericSlug))
    }
    let sit = try store.add(name: "Sit", height: height(1))
    XCTAssertThrowsError(try store.rename(id: sit.id, to: "４２")) {
      XCTAssertEqual($0 as? PositionError, .invalidName(.numericSlug))
    }
    XCTAssertEqual(store.positions.count, 1)
  }

  func testMatchingByNameThenSlug() throws {
    let store = makeStore()
    try store.add(name: "Żółte biurko", height: height(1))
    try store.add(name: "Standing", height: height(2))
    XCTAssertEqual(store.position(matching: "żółte BIURKO")?.name, "Żółte biurko")
    XCTAssertEqual(store.position(matching: "zolte-biurko")?.name, "Żółte biurko")
    XCTAssertEqual(store.position(matching: "ZOLTE-BIURKO")?.name, "Żółte biurko")
    XCTAssertEqual(store.position(matching: "standing")?.name, "Standing")
    XCTAssertEqual(store.position(matching: "  zolte-biurko\n")?.name, "Żółte biurko")
    XCTAssertNil(store.position(matching: "zolte"))
    XCTAssertNil(store.position(matching: "zolte biurko"))
    XCTAssertNil(store.position(matching: "stand"))
  }

  func testNameBeatsSlugEvenIfAnotherPositionComesFirst() {
    let positions = [
      Position(name: "Żółte biurko", height: height(1)),
      Position(name: "zolte-biurko", height: height(2)),
    ]
    XCTAssertEqual(PositionName.match("zolte-biurko", in: positions)?.height.raw, 2)
    XCTAssertEqual(
      PositionName.match("zolte-biurko", in: positions.reversed())?.height.raw, 2)
    XCTAssertEqual(PositionName.match("Żółte biurko", in: positions)?.height.raw, 1)
  }

  func testUpdateHeight() throws {
    let store = makeStore()
    let position = try store.add(name: "Sit", height: height(1050))
    try store.updateHeight(id: position.id, to: height(1200))
    XCTAssertEqual(store.position(id: position.id)?.height.raw, 1200)
    XCTAssertEqual(store.position(id: position.id)?.name, "Sit")
  }

  func testUpdateHeightUnknown() {
    let store = makeStore()
    XCTAssertThrowsError(try store.updateHeight(id: UUID(), to: height(1))) {
      XCTAssertEqual($0 as? PositionError, .unknownPosition)
    }
  }

  func testRename() throws {
    let store = makeStore()
    let position = try store.add(name: "Sit", height: height(1050))
    try store.rename(id: position.id, to: " Desk sit ")
    XCTAssertEqual(store.position(id: position.id)?.name, "Desk sit")
    XCTAssertNil(store.position(named: "Sit"))
  }

  func testRenameToCaseVariantOfOwnName() throws {
    let store = makeStore()
    let position = try store.add(name: "sit", height: height(1050))
    try store.rename(id: position.id, to: "SIT")
    XCTAssertEqual(store.position(id: position.id)?.name, "SIT")
  }

  func testRenameErrors() throws {
    let store = makeStore()
    let sit = try store.add(name: "Sit", height: height(1050))
    try store.add(name: "Stand", height: height(5000))
    XCTAssertThrowsError(try store.rename(id: sit.id, to: "stand")) {
      XCTAssertEqual($0 as? PositionError, .duplicateName(clashingWith: "Stand"))
    }
    XCTAssertThrowsError(try store.rename(id: sit.id, to: "")) {
      XCTAssertEqual($0 as? PositionError, .invalidName(.empty))
    }
    XCTAssertThrowsError(try store.rename(id: sit.id, to: "42")) {
      XCTAssertEqual($0 as? PositionError, .invalidName(.numeric))
    }
    XCTAssertThrowsError(try store.rename(id: UUID(), to: "Other")) {
      XCTAssertEqual($0 as? PositionError, .unknownPosition)
    }
    XCTAssertEqual(store.position(id: sit.id)?.name, "Sit")
  }

  func testRemove() throws {
    let store = makeStore()
    let sit = try store.add(name: "Sit", height: height(1050))
    let stand = try store.add(name: "Stand", height: height(5000))
    try store.remove(id: sit.id)
    XCTAssertEqual(store.positions, [stand])
    XCTAssertThrowsError(try store.remove(id: sit.id)) {
      XCTAssertEqual($0 as? PositionError, .unknownPosition)
    }
  }

  func testRemoveFreesName() throws {
    let store = makeStore()
    let sit = try store.add(name: "Sit", height: height(1050))
    try store.remove(id: sit.id)
    XCTAssertNoThrow(try store.add(name: "sit", height: height(1)))
  }

  func testMove() throws {
    let store = makeStore()
    let a = try store.add(name: "A", height: height(1))
    try store.add(name: "B", height: height(2))
    try store.add(name: "C", height: height(3))
    try store.move(id: a.id, toIndex: 2)
    XCTAssertEqual(store.positions.map(\.name), ["B", "C", "A"])
    try store.move(id: a.id, toIndex: 0)
    XCTAssertEqual(store.positions.map(\.name), ["A", "B", "C"])
    try store.move(id: a.id, toIndex: 1)
    XCTAssertEqual(store.positions.map(\.name), ["B", "A", "C"])
  }

  func testMoveClampsIndex() throws {
    let store = makeStore()
    let a = try store.add(name: "A", height: height(1))
    try store.add(name: "B", height: height(2))
    try store.move(id: a.id, toIndex: 99)
    XCTAssertEqual(store.positions.map(\.name), ["B", "A"])
    try store.move(id: a.id, toIndex: -3)
    XCTAssertEqual(store.positions.map(\.name), ["A", "B"])
  }

  func testMoveUnknown() {
    let store = makeStore()
    XCTAssertThrowsError(try store.move(id: UUID(), toIndex: 0)) {
      XCTAssertEqual($0 as? PositionError, .unknownPosition)
    }
  }

  func testLookupByNameIsCaseAndNormalizationInsensitive() throws {
    let store = makeStore()
    let bed = try store.add(name: "ŁÓŻKO", height: height(1))
    let cafe = try store.add(name: "Café", height: height(2))
    XCTAssertEqual(store.position(named: "łóżko"), bed)
    XCTAssertEqual(store.position(named: "  ŁóŻkO "), bed)
    XCTAssertEqual(store.position(named: "CAFE\u{301}"), cafe)
    XCTAssertNil(store.position(named: "missing"))
  }

  func testPersistenceRoundTrip() throws {
    let store = makeStore()
    let sit = try store.add(name: "Sit", height: height(1050))
    let stand = try store.add(name: "Stand", height: height(5000))
    try store.rename(id: sit.id, to: "Sitting")
    try store.move(id: stand.id, toIndex: 0)

    let reloaded = makeStore()
    XCTAssertEqual(reloaded.positions, store.positions)
    XCTAssertEqual(reloaded.positions.map(\.name), ["Stand", "Sitting"])
    XCTAssertNil(reloaded.warning)
    XCTAssertFalse(reloaded.isReadOnly)
  }

  func testFileFormatV1() throws {
    let store = makeStore()
    let sit = try store.add(name: "Sit", height: height(1050))
    let data = try Data(contentsOf: fileURL)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["version"] as? Int, 1)
    let positions = try XCTUnwrap(json["positions"] as? [[String: Any]])
    XCTAssertEqual(positions.count, 1)
    XCTAssertEqual(Set(positions[0].keys), ["id", "name", "raw"])
    XCTAssertEqual(positions[0]["id"] as? String, sit.id.uuidString)
    XCTAssertEqual(positions[0]["name"] as? String, "Sit")
    XCTAssertEqual(positions[0]["raw"] as? Int, 1050)
  }

  func testLoadsDocumentedFormat() throws {
    try writeRaw(
      """
      {
        "version": 1,
        "positions": [
          { "id": "6F1C0000-0000-4000-8000-000000000001", "name": "Sit", "raw": 1050 },
          { "id": "A03B0000-0000-4000-8000-000000000002", "name": "Stand", "raw": 5000 }
        ]
      }
      """)
    let store = makeStore()
    XCTAssertEqual(store.positions.map(\.name), ["Sit", "Stand"])
    XCTAssertEqual(store.positions.map(\.height.raw), [1050, 5000])
    XCTAssertNil(store.warning)
  }

  func testCreatesDirectoryWithOwnerOnlyPermissions() throws {
    let store = makeStore()
    try store.add(name: "Sit", height: height(1))
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
  }

  func testWritesLeaveNoTemporaryFiles() throws {
    let store = makeStore()
    try store.add(name: "Sit", height: height(1))
    try store.add(name: "Stand", height: height(2))
    XCTAssertEqual(try directoryContents(), ["positions.json"])
  }

  func testUnknownFutureVersionIsReadOnly() throws {
    let original = """
      {"version": 2, "positions": [{"id": "x", "name": "Sit", "future": true}]}
      """
    try writeRaw(original)
    let store = makeStore()
    XCTAssertTrue(store.isReadOnly)
    XCTAssertEqual(store.warning, .unsupportedVersion(2))
    XCTAssertTrue(store.positions.isEmpty)

    XCTAssertThrowsError(try store.add(name: "Sit", height: height(1))) {
      XCTAssertEqual($0 as? PositionError, .readOnly)
    }
    XCTAssertThrowsError(try store.remove(id: UUID())) {
      XCTAssertEqual($0 as? PositionError, .readOnly)
    }
    XCTAssertThrowsError(try store.rename(id: UUID(), to: "X")) {
      XCTAssertEqual($0 as? PositionError, .readOnly)
    }
    XCTAssertThrowsError(try store.updateHeight(id: UUID(), to: height(1))) {
      XCTAssertEqual($0 as? PositionError, .readOnly)
    }
    XCTAssertThrowsError(try store.move(id: UUID(), toIndex: 0)) {
      XCTAssertEqual($0 as? PositionError, .readOnly)
    }
    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), original)
    XCTAssertEqual(try directoryContents(), ["positions.json"])
  }

  func testCorruptFileIsMovedAside() throws {
    try writeRaw("{ not json")
    let store = makeStore()
    XCTAssertTrue(store.positions.isEmpty)
    XCTAssertFalse(store.isReadOnly)
    guard case .corruptFileMovedAside(let moved) = store.warning else {
      return XCTFail("expected corrupt warning, got \(String(describing: store.warning))")
    }
    XCTAssertEqual(moved.lastPathComponent, "positions.corrupt-20270115T080000Z.json")
    XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "{ not json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

    try store.add(name: "Sit", height: height(1))
    XCTAssertEqual(
      try directoryContents(), ["positions.corrupt-20270115T080000Z.json", "positions.json"])
    XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "{ not json")
  }

  func testCorruptFilesNeverOverwriteEachOther() throws {
    try writeRaw("first")
    _ = makeStore()
    try writeRaw("second")
    _ = makeStore()
    let corrupt = try directoryContents().filter { $0.hasPrefix("positions.corrupt-") }
    XCTAssertEqual(corrupt.count, 2)
    let contents = try corrupt.map {
      try String(contentsOf: directory.appending(path: $0), encoding: .utf8)
    }
    XCTAssertEqual(Set(contents), ["first", "second"])
  }

  func testStructurallyInvalidFilesAreMovedAside() throws {
    let cases = [
      #"{"version": 1}"#,
      #"{"version": 0, "positions": []}"#,
      #"{"version": 1, "positions": [{"id": "nope", "name": "Sit", "raw": 1}]}"#,
      """
      {"version": 1, "positions": [
        {"id": "6F1C0000-0000-4000-8000-000000000001", "name": "Sit", "raw": 1},
        {"id": "6F1C0000-0000-4000-8000-000000000001", "name": "Stand", "raw": 2}]}
      """,
      "[]",
      "",
    ]
    for content in cases {
      try? FileManager.default.removeItem(at: directory)
      try writeRaw(content)
      let store = makeStore()
      XCTAssertTrue(store.positions.isEmpty, content)
      XCTAssertFalse(store.isReadOnly, content)
      guard case .corruptFileMovedAside = store.warning else {
        XCTFail("expected corrupt warning for \(content)")
        continue
      }
    }
  }

  func testRuleViolatingContentIsReadOnlyKeepsValidRecordsAndLeavesFileInPlace() throws {
    let id1 = "6F1C0000-0000-4000-8000-000000000001"
    let id2 = "6F1C0000-0000-4000-8000-000000000002"
    let cases: [(content: String, visible: [String])] = [
      (#"{"version": 1, "positions": [{"id": "\#(id1)", "name": "Sit", "raw": 7000}]}"#, []),
      (#"{"version": 1, "positions": [{"id": "\#(id1)", "name": "Sit", "raw": -1}]}"#, []),
      (#"{"version": 1, "positions": [{"id": "\#(id1)", "name": " ", "raw": 1}]}"#, []),
      (#"{"version": 1, "positions": [{"id": "\#(id1)", "name": "100", "raw": 1}]}"#, ["100"]),
      (
        """
        {"version": 1, "positions": [
          {"id": "\(id1)", "name": "Sit", "raw": 1},
          {"id": "\(id2)", "name": "SIT", "raw": 2}]}
        """, ["Sit", "SIT"]
      ),
      (
        """
        {"version": 1, "positions": [
          {"id": "\(id1)", "name": "Sit", "raw": 7000},
          {"id": "\(id2)", "name": " Stand ", "raw": 2}]}
        """, ["Stand"]
      ),
    ]
    for (content, visible) in cases {
      try? FileManager.default.removeItem(at: directory)
      try writeRaw(content)
      let store = makeStore()
      XCTAssertEqual(store.warning, .invalidContent, content)
      XCTAssertTrue(store.isReadOnly, content)
      XCTAssertEqual(store.positions.map(\.name), visible, content)
      XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), content)
      XCTAssertEqual(try directoryContents(), ["positions.json"])
      XCTAssertThrowsError(try store.add(name: "Other", height: height(1))) {
        XCTAssertEqual($0 as? PositionError, .readOnly)
      }
    }
  }

  func testOldRuleViolatingFileKeepsValidRecordsMovableByName() throws {
    try writeRaw(
      """
      {"version": 1, "positions": [
        {"id": "6F1C0000-0000-4000-8000-000000000001", "name": "Sit", "raw": 7000},
        {"id": "6F1C0000-0000-4000-8000-000000000002", "name": "Stand", "raw": 5000}]}
      """)
    let store = makeStore()
    XCTAssertTrue(store.isReadOnly)
    XCTAssertEqual(store.position(matching: "stand")?.height.raw, 5000)
    XCTAssertNil(store.position(matching: "sit"))
  }

  func testSlugCollisionsInAFileLoadWritableWithNoUsableSlug() throws {
    try writeRaw(
      """
      {"version": 1, "positions": [
        {"id": "6F1C0000-0000-4000-8000-000000000001", "name": "Żółte", "raw": 1},
        {"id": "6F1C0000-0000-4000-8000-000000000002", "name": "Zolte!", "raw": 2},
        {"id": "6F1C0000-0000-4000-8000-000000000003", "name": "Standing", "raw": 3}]}
      """)
    let store = makeStore()
    XCTAssertNil(store.warning)
    XCTAssertFalse(store.isReadOnly)
    XCTAssertEqual(store.positions.map(\.name), ["Żółte", "Zolte!", "Standing"])
    XCTAssertNil(store.position(matching: "zolte"))
    XCTAssertEqual(store.position(matching: "żółte")?.height.raw, 1)
    XCTAssertEqual(store.position(matching: "ZOLTE!")?.height.raw, 2)
    XCTAssertEqual(store.position(matching: "standing")?.height.raw, 3)
    XCTAssertEqual(store.positions.map(store.usableSlug(of:)), ["", "", "standing"])

    let first = try XCTUnwrap(store.positions.first)
    try store.rename(id: first.id, to: "Żółte biurko")
    XCTAssertEqual(
      store.positions.map(store.usableSlug(of:)), ["zolte-biurko", "zolte", "standing"])
    XCTAssertEqual(store.position(matching: "zolte")?.height.raw, 2)
  }

  func testNumericSlugInAFileLoadsWritableAndIsMovableByName() throws {
    try writeRaw(
      """
      {"version": 1, "positions": [
        {"id": "6F1C0000-0000-4000-8000-000000000001", "name": "#1", "raw": 1000},
        {"id": "6F1C0000-0000-4000-8000-000000000002", "name": "１２３", "raw": 2000}]}
      """)
    let store = makeStore()
    XCTAssertNil(store.warning)
    XCTAssertFalse(store.isReadOnly)
    XCTAssertEqual(store.positions.map(\.name), ["#1", "１２３"])
    XCTAssertEqual(store.position(matching: "#1")?.height.raw, 1000)
    XCTAssertEqual(store.position(matching: "１２３")?.height.raw, 2000)
    XCTAssertNil(store.position(matching: "1"))
    XCTAssertEqual(store.positions.map(store.usableSlug(of:)), ["", ""])
  }

  func testLoadNormalizesNames() throws {
    try writeRaw(
      """
      {"version": 1, "positions": [
        {"id": "6F1C0000-0000-4000-8000-000000000001", "name": "  Cafe\u{0301} ", "raw": 1}]}
      """)
    let store = makeStore()
    let name = try XCTUnwrap(store.positions.first?.name)
    XCTAssertEqual(Array(name.unicodeScalars), Array("Caf\u{E9}".unicodeScalars))
    XCTAssertEqual(store.position(named: "café")?.height.raw, 1)
    XCTAssertNil(store.warning)
  }

  func testRemoveAndUpdateHeightSurviveReload() throws {
    let store = makeStore()
    let sit = try store.add(name: "Sit", height: height(1050))
    let stand = try store.add(name: "Stand", height: height(5000))
    let focus = try store.add(name: "Focus", height: height(3000))
    try store.remove(id: stand.id)
    try store.updateHeight(id: focus.id, to: height(3500))

    let reloaded = makeStore()
    XCTAssertEqual(reloaded.positions.map(\.name), ["Sit", "Focus"])
    XCTAssertEqual(reloaded.position(id: sit.id)?.height.raw, 1050)
    XCTAssertEqual(reloaded.position(id: focus.id)?.height.raw, 3500)
    XCTAssertNil(reloaded.position(id: stand.id))
  }

  func testMoveFromOffsetsMatchesSwiftUISemantics() throws {
    func names(after offsets: IndexSet, to destination: Int) throws -> [String] {
      let store = makeStore()
      for name in ["A", "B", "C", "D"] { try store.add(name: name, height: height(1)) }
      try store.move(fromOffsets: offsets, toOffset: destination)
      let result = store.positions.map(\.name)
      try FileManager.default.removeItem(at: directory)
      return result
    }
    XCTAssertEqual(try names(after: [0], to: 3), ["B", "C", "A", "D"])
    XCTAssertEqual(try names(after: [0], to: 4), ["B", "C", "D", "A"])
    XCTAssertEqual(try names(after: [3], to: 0), ["D", "A", "B", "C"])
    XCTAssertEqual(try names(after: [2], to: 1), ["A", "C", "B", "D"])
    XCTAssertEqual(try names(after: [1], to: 2), ["A", "B", "C", "D"])
    XCTAssertEqual(try names(after: [0, 1], to: 4), ["C", "D", "A", "B"])
    XCTAssertEqual(try names(after: [0, 3], to: 2), ["B", "A", "D", "C"])
    XCTAssertEqual(try names(after: [2, 3], to: 0), ["C", "D", "A", "B"])
    XCTAssertEqual(try names(after: [1], to: 99), ["A", "C", "D", "B"])
  }

  func testMoveFromOffsetsPersistsAndValidates() throws {
    let store = makeStore()
    try store.add(name: "A", height: height(1))
    try store.add(name: "B", height: height(2))
    try store.move(fromOffsets: [0], toOffset: 2)
    XCTAssertEqual(makeStore().positions.map(\.name), ["B", "A"])
    XCTAssertThrowsError(try store.move(fromOffsets: [5], toOffset: 0)) {
      XCTAssertEqual($0 as? PositionError, .unknownPosition)
    }
  }

  func testUnreadableFileIsReadOnlyAndLeftInPlace() throws {
    try XCTSkipIf(getuid() == 0, "root ignores file permissions")
    try writeRaw(#"{"version": 1, "positions": []}"#)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    let store = makeStore()
    XCTAssertEqual(store.warning, .corruptFileLeftInPlace)
    XCTAssertTrue(store.isReadOnly)
    XCTAssertThrowsError(try store.add(name: "Sit", height: height(1))) {
      XCTAssertEqual($0 as? PositionError, .readOnly)
    }
  }

  func testSaveFailureRollsBack() throws {
    let store = makeStore()
    try store.add(name: "Sit", height: height(1))
    try FileManager.default.removeItem(at: directory)
    try Data().write(to: directory)
    XCTAssertThrowsError(try store.add(name: "Stand", height: height(2))) {
      guard case .saveFailed = $0 as? PositionError else {
        return XCTFail("expected saveFailed, got \($0)")
      }
    }
    XCTAssertEqual(store.positions.map(\.name), ["Sit"])
  }
}
