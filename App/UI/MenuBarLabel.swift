import DeskKit
import SwiftUI

struct MenuBarLabel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 4) {
      if model.settings.showsIcon {
        Image(
          systemName: Self.symbol(
            for: model.controller.state, heightRaw: model.controller.heightRaw)
        )
        .frame(width: Self.iconWidth)
      }
      Text(text).monospacedDigit()
    }
  }

  private var text: String {
    let height = model.heightCm.map(Formatting.cm) ?? "--.-"
    let padding = String(repeating: "\u{2007}", count: max(0, 5 - height.count))
    var text = padding + height
    if model.settings.showsUnit { text += " cm" }
    if model.isSimulated { text = "SIM " + text }
    return text
  }

  static let iconWidth: CGFloat = 16

  static func symbol(for state: DeskState, heightRaw: Int?) -> String {
    switch state {
    case .connected(.idle): "figure.stand"
    case .connected(.moving(let kind)):
      kind.direction(currentRaw: heightRaw) == .down ? "arrow.down" : "arrow.up"
    case .scanning, .connecting: "dot.radiowaves.left.and.right"
    case .pairingRequired: "link.badge.plus"
    case .bluetoothOff: "antenna.radiowaves.left.and.right.slash"
    case .unauthorized, .failed: "exclamationmark.triangle"
    case .disconnected: "minus.circle"
    }
  }

}
