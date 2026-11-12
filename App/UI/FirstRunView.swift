import DeskKit
import SwiftUI

struct FirstRunView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Connect your desk").font(.title3.bold())
      Text(
        "Idasen talks to your IKEA IDÅSEN desk over Bluetooth. macOS will ask for permission to use Bluetooth when you continue."
      )
      Text(
        "Before you continue, put the desk in pairing mode: hold the Bluetooth button on the desk panel until the LED blinks."
      )
      .foregroundStyle(.secondary)
      Button("Continue") { model.acceptExplanation() }
        .keyboardShortcut(.defaultAction)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct ConnectionPanel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      switch model.controller.state {
      case .scanning:
        if model.controller.discoveredDesks.isEmpty {
          Text(
            "Put the desk in pairing mode: hold the Bluetooth button on the desk panel until the LED blinks."
          )
          .font(.callout)
          ProgressView().controlSize(.small)
        } else {
          Text("Choose your desk").font(.subheadline.bold())
          ForEach(model.controller.discoveredDesks) { desk in
            Button {
              model.connect(to: desk)
            } label: {
              HStack {
                Text(desk.name)
                Spacer()
                Text("\(desk.rssi) dBm").foregroundStyle(.secondary).monospacedDigit()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      case .connecting:
        ProgressView().controlSize(.small)
      case .unauthorized:
        Button("Open Bluetooth Privacy Settings") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
          {
            NSWorkspace.shared.open(url)
          }
        }
      case .disconnected, .pairingRequired, .failed:
        Button("Try Again") { model.connect() }
      case .bluetoothOff, .connected:
        EmptyView()
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
