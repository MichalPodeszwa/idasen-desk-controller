import DeskKit
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    VStack(alignment: .leading, spacing: 12) {
      Text("Settings").font(.title3.bold())

      VStack(alignment: .leading, spacing: 4) {
        Stepper(value: $settings.calibrationMM, in: -100...100, step: 0.5) {
          Text("Calibration offset: \(String(format: "%+.1f", settings.calibrationMM)) mm")
            .monospacedDigit()
        }
        Text(
          "Shifts every displayed height. Saved positions keep their physical position and only their labels change."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Menu bar").font(.subheadline.bold())
        Toggle("Show state icon", isOn: $settings.showsIcon)
        Toggle("Show unit (cm)", isOn: $settings.showsUnit)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Toggle(
          "Launch at login",
          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        cliRow
        if let notice = model.settingsNotice {
          Text(notice).font(.callout).foregroundStyle(.red)
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("Bluetooth").font(.subheadline.bold())
        Text("Permission: \(model.authorizationLabel)").font(.callout)
        Button("Forget desk") { model.forgetDesk() }
      }

      Text("Version \(Self.version)").font(.caption).foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .task { await model.checkCLIPath() }
  }

  @ViewBuilder
  private var cliRow: some View {
    switch model.cliStatus {
    case .installed:
      HStack {
        Label("Command line tool installed", systemImage: "checkmark.circle")
        Spacer()
        Button("Remove") { model.uninstallCLI() }
      }
      Text(model.cliLinkPath).font(.caption).foregroundStyle(.secondary)
      switch model.cliPathCheck {
      case .missing:
        Text(
          "~/.local/bin is not on your login shell's PATH. Add it to your shell profile to use `idasen`."
        )
        .font(.caption).foregroundStyle(.orange)
      case .unavailable:
        Text("Couldn't check your shell's PATH. If `idasen` isn't found, add ~/.local/bin to it.")
          .font(.caption).foregroundStyle(.secondary)
      case .unknown, .onPath:
        EmptyView()
      }
    case .notInstalled, .pointsElsewhere, .blockedByFile:
      Button("Install command line tool") { model.installCLI() }
      if case .pointsElsewhere(let destination) = model.cliStatus {
        Text("\(model.cliLinkPath) currently points to \(destination)")
          .font(.caption).foregroundStyle(.secondary)
      }
      if model.cliStatus == .blockedByFile {
        Text("\(model.cliLinkPath) already exists and is not a symlink")
          .font(.caption).foregroundStyle(.orange)
      }
    }
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }
}
