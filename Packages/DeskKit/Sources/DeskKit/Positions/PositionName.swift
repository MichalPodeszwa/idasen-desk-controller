import Foundation

public enum PositionName {
  public enum Rejection: Error, Equatable, Sendable {
    case empty
    case numeric
    case numericSlug
  }

  public static func normalized(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
  }

  public static func key(_ name: String) -> String {
    normalized(name).folding(options: .caseInsensitive, locale: nil)
      .precomposedStringWithCanonicalMapping
  }

  public static func slug(_ name: String) -> String {
    let transformed =
      name.precomposedStringWithCanonicalMapping.applyingTransform(
        StringTransform("Any-Latin; Latin-ASCII; Lower"), reverse: false) ?? ""
    var parts: [String] = []
    var current = ""
    for scalar in transformed.unicodeScalars {
      if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
        current.unicodeScalars.append(scalar)
      } else if !current.isEmpty {
        parts.append(current)
        current = ""
      }
    }
    if !current.isEmpty { parts.append(current) }
    return parts.joined(separator: "-")
  }

  public static func match(_ target: String, in positions: [Position]) -> Position? {
    let key = key(target)
    if let exact = positions.first(where: { Self.key($0.name) == key }) { return exact }
    let slug = normalized(target).lowercased()
    guard !slug.isEmpty, Double(slug) == nil else { return nil }
    let candidates = positions.filter { $0.slug == slug }
    return candidates.count == 1 ? candidates[0] : nil
  }

  public static func usableSlug(of position: Position, in positions: [Position]) -> String {
    let slug = position.slug
    guard !slug.isEmpty, Double(slug) == nil, positions.count(where: { $0.slug == slug }) == 1
    else { return "" }
    return slug
  }

  public static func isNumeric(_ name: String) -> Bool {
    let trimmed = normalized(name)
    if Double(trimmed) != nil { return true }
    guard trimmed.filter({ $0 == "," }).count == 1 else { return false }
    return Double(trimmed.replacingOccurrences(of: ",", with: ".")) != nil
  }

  static func validatedIgnoringSlug(_ name: String) throws(Rejection) -> String {
    let normalized = normalized(name)
    guard !normalized.isEmpty else { throw .empty }
    guard !isNumeric(normalized) else { throw .numeric }
    return normalized
  }

  public static func validated(_ name: String) throws(Rejection) -> String {
    let normalized = try validatedIgnoringSlug(name)
    guard Double(slug(normalized)) == nil else { throw .numericSlug }
    return normalized
  }
}
