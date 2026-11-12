import DeskKit
import Foundation

@MainActor
public protocol DeskMoveTicket: AnyObject {
  var id: MoveID { get }
  func result() async -> Result<Int, DeskControllerError>
}

@MainActor
public protocol DeskControlling: AnyObject {
  var state: DeskState { get }
  var heightRaw: Int? { get }
  var speedRaw: Int { get }
  var baseMM: Double { get }
  var storedPositions: [Position] { get }
  var notFoundHint: Bool { get }

  func watch() -> AsyncStream<DeskEvent>
  func connect()
  func beginMove(toRaw raw: Int) throws(DeskControllerError) -> any DeskMoveTicket
  func beginMove(byRaw delta: Int) throws(DeskControllerError) -> any DeskMoveTicket
  func beginMove(toPositionNamed name: String) throws(DeskControllerError) -> any DeskMoveTicket
  func stop() async
  func cancel(moveID: MoveID) async
  func savePosition(named name: String, raw: Int?) throws(DeskControllerError) -> Position
  func removePosition(named name: String) throws(DeskControllerError)
  func renamePosition(from name: String, to newName: String) throws(DeskControllerError)
}

extension MoveTicket: DeskMoveTicket {}

extension DeskController: DeskControlling {
  public var storedPositions: [Position] {
    positions.positions
  }

  public func beginMove(toRaw raw: Int) throws(DeskControllerError) -> any DeskMoveTicket {
    try startMove(toRaw: raw)
  }

  public func beginMove(byRaw delta: Int) throws(DeskControllerError) -> any DeskMoveTicket {
    try startMove(byRaw: delta)
  }

  public func beginMove(toPositionNamed name: String) throws(DeskControllerError)
    -> any DeskMoveTicket
  {
    try startMove(toPositionNamed: name)
  }

  public func removePosition(named name: String) throws(DeskControllerError) {
    guard let position = positions.position(matching: name) else {
      throw .positions(.unknownPosition)
    }
    do throws(PositionError) {
      try positions.remove(id: position.id)
    } catch {
      throw .positions(error)
    }
  }

  public func renamePosition(from name: String, to newName: String) throws(DeskControllerError) {
    guard let position = positions.position(matching: name) else {
      throw .positions(.unknownPosition)
    }
    do throws(PositionError) {
      try positions.rename(id: position.id, to: newName)
    } catch {
      throw .positions(error)
    }
  }
}
