import Foundation
import Observation

public enum PositionError: Error, Equatable, Sendable {
  case invalidName(PositionName.Rejection)
  case duplicateName(clashingWith: String)
  case unknownPosition
  case readOnly
  case saveFailed(String)
}

public enum PositionStoreWarning: Equatable, Sendable {
  case corruptFileMovedAside(URL)
  case corruptFileLeftInPlace
  case invalidContent
  case unsupportedVersion(Int)
}

@MainActor
@Observable
public final class PositionStore {
  public static let currentVersion = 1
  public static let fileName = "positions.json"
  private static let maxCorruptNameAttempts = 1000

  public private(set) var positions: [Position] = []
  public private(set) var warning: PositionStoreWarning?

  public private(set) var isReadOnly = false

  @ObservationIgnored private let directory: URL
  @ObservationIgnored private let now: @Sendable () -> Date

  private var fileURL: URL { directory.appending(path: Self.fileName) }

  public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.directory = directory
    self.now = now
    load()
  }

  public func position(id: UUID) -> Position? {
    positions.first { $0.id == id }
  }

  public func usableSlug(of position: Position) -> String {
    PositionName.usableSlug(of: position, in: positions)
  }

  public func position(named name: String) -> Position? {
    let key = PositionName.key(name)
    return positions.first { PositionName.key($0.name) == key }
  }

  public func position(matching target: String) -> Position? {
    PositionName.match(target, in: positions)
  }

  @discardableResult
  public func add(name: String, height: DeskHeight) throws(PositionError) -> Position {
    try requireWritable()
    let name = try validatedName(name, excluding: nil)
    let position = Position(name: name, height: height)
    try commit(positions + [position])
    return position
  }

  public func updateHeight(id: UUID, to height: DeskHeight) throws(PositionError) {
    try requireWritable()
    var updated = positions
    guard let index = updated.firstIndex(where: { $0.id == id }) else { throw .unknownPosition }
    updated[index].height = height
    try commit(updated)
  }

  public func rename(id: UUID, to name: String) throws(PositionError) {
    try requireWritable()
    var updated = positions
    guard let index = updated.firstIndex(where: { $0.id == id }) else { throw .unknownPosition }
    updated[index].name = try validatedName(name, excluding: id)
    try commit(updated)
  }

  public func remove(id: UUID) throws(PositionError) {
    try requireWritable()
    var updated = positions
    guard let index = updated.firstIndex(where: { $0.id == id }) else { throw .unknownPosition }
    updated.remove(at: index)
    try commit(updated)
  }

  public func move(id: UUID, toIndex destination: Int) throws(PositionError) {
    try requireWritable()
    var updated = positions
    guard let index = updated.firstIndex(where: { $0.id == id }) else { throw .unknownPosition }
    let position = updated.remove(at: index)
    updated.insert(position, at: min(max(destination, 0), updated.count))
    try commit(updated)
  }

  public func move(fromOffsets offsets: IndexSet, toOffset destination: Int)
    throws(PositionError)
  {
    try requireWritable()
    guard offsets.allSatisfy({ positions.indices.contains($0) }) else { throw .unknownPosition }
    let destination = min(max(destination, 0), positions.count)
    let moving = offsets.map { positions[$0] }
    var updated = positions.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    updated.insert(contentsOf: moving, at: destination - offsets.count(in: 0..<destination))
    try commit(updated)
  }

  private func requireWritable() throws(PositionError) {
    if isReadOnly { throw .readOnly }
  }

  private func validatedName(_ name: String, excluding id: UUID?) throws(PositionError) -> String {
    let normalized: String
    do {
      normalized = try PositionName.validated(name)
    } catch {
      throw .invalidName(error)
    }
    let key = PositionName.key(normalized)
    let slug = PositionName.slug(normalized)
    if let clash = positions.first(where: {
      $0.id != id && (PositionName.key($0.name) == key || (!slug.isEmpty && $0.slug == slug))
    }) {
      throw .duplicateName(clashingWith: clash.name)
    }
    return normalized
  }

  private func commit(_ updated: [Position]) throws(PositionError) {
    do {
      try write(updated)
    } catch {
      throw .saveFailed(error.localizedDescription)
    }
    positions = updated
  }

  private func write(_ positions: [Position]) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(
      PositionsFile(
        version: Self.currentVersion,
        positions: positions.map { PositionRecord(id: $0.id, name: $0.name, raw: $0.height.raw) }))
    try data.write(to: fileURL, options: .atomic)
  }

  private func load() {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return
    } catch {
      warning = .corruptFileLeftInPlace
      isReadOnly = true
      return
    }

    if let header = try? JSONDecoder().decode(PositionsFileHeader.self, from: data),
      header.version > Self.currentVersion
    {
      warning = .unsupportedVersion(header.version)
      isReadOnly = true
      return
    }

    let records: [PositionRecord]
    do {
      let file = try JSONDecoder().decode(PositionsFile.self, from: data)
      guard file.version == Self.currentVersion else { throw PositionsFileError.invalid }
      guard Set(file.positions.map(\.id)).count == file.positions.count else {
        throw PositionsFileError.invalid
      }
      records = file.positions
    } catch {
      moveCorruptFileAside()
      return
    }

    let (loaded, violatesRules) = Self.usable(records)
    positions = loaded
    if violatesRules {
      warning = .invalidContent
      isReadOnly = true
    }
  }

  private static func usable(_ records: [PositionRecord]) -> ([Position], violatesRules: Bool) {
    var keys: Set<String> = []
    var result: [Position] = []
    var violatesRules = false
    for record in records {
      guard let height = DeskHeight(validating: record.raw) else {
        violatesRules = true
        continue
      }
      let name = PositionName.normalized(record.name)
      guard !name.isEmpty else {
        violatesRules = true
        continue
      }
      if (try? PositionName.validatedIgnoringSlug(name)) == nil
        || !keys.insert(PositionName.key(name)).inserted
      {
        violatesRules = true
      }
      result.append(Position(id: record.id, name: name, height: height))
    }
    return (result, violatesRules)
  }

  private func moveCorruptFileAside() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let stamp = formatter.string(from: now())

    for attempt in 0..<Self.maxCorruptNameAttempts {
      let suffix = attempt == 0 ? "" : "-\(attempt)"
      let target = directory.appending(path: "positions.corrupt-\(stamp)\(suffix).json")
      guard !FileManager.default.fileExists(atPath: target.path) else { continue }
      do {
        try FileManager.default.moveItem(at: fileURL, to: target)
        warning = .corruptFileMovedAside(target)
      } catch {
        warning = .corruptFileLeftInPlace
        isReadOnly = true
      }
      return
    }
    warning = .corruptFileLeftInPlace
    isReadOnly = true
  }
}

private struct PositionRecord: Codable {
  var id: UUID
  var name: String
  var raw: Int
}

private struct PositionsFile: Codable {
  var version: Int
  var positions: [PositionRecord]
}

private struct PositionsFileHeader: Decodable {
  var version: Int
}

private enum PositionsFileError: Error {
  case invalid
}
