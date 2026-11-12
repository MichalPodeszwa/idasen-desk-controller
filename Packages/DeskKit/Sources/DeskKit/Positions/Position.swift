import Foundation

public struct Position: Identifiable, Hashable, Sendable {
  public let id: UUID
  public var name: String {
    didSet { slug = PositionName.slug(name) }
  }
  public var height: DeskHeight
  public private(set) var slug: String

  public init(id: UUID = UUID(), name: String, height: DeskHeight) {
    self.id = id
    self.name = name
    self.slug = PositionName.slug(name)
    self.height = height
  }
}
