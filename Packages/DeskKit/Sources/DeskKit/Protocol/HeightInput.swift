import Foundation

public enum HeightInput {
  public static func parse(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized =
      trimmed.filter({ $0 == "," }).count == 1
      ? trimmed.replacingOccurrences(of: ",", with: ".") : trimmed
    guard let value = Double(normalized), value.isFinite else { return nil }
    return value
  }
}
