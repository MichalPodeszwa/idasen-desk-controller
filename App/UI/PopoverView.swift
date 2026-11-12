import SwiftUI

struct PopoverView: View {
  private enum Page {
    case main
    case settings
  }

  @Environment(AppModel.self) private var model
  @State private var page = Page.main

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      switch page {
      case .main:
        if model.needsExplanation {
          FirstRunView()
        } else {
          MainPage()
        }
      case .settings:
        SettingsView()
      }
      Divider()
      footer
    }
    .padding(14)
    .frame(width: 320)
  }

  private var header: some View {
    HStack {
      Text("Idasen").font(.headline)
      if model.isSimulated {
        Text("SIMULATED")
          .font(.caption2.bold())
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.orange, in: Capsule())
          .foregroundStyle(.white)
      }
      Spacer()
    }
  }

  private var footer: some View {
    HStack {
      Button {
        page = page == .main ? .settings : .main
        model.refreshInstallState()
      } label: {
        Label(
          page == .main ? "Settings" : "Done",
          systemImage: page == .main ? "gearshape" : "chevron.left")
      }
      .buttonStyle(.borderless)
      Spacer()
      if let problem = model.serverProblem {
        Text(problem).font(.caption).foregroundStyle(.orange)
      }
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
  }
}

private struct MainPage: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HeightHeader()
      if model.isConnected {
        ControlsSection()
      } else {
        ConnectionPanel()
      }
      if let notice = model.notice {
        Text(notice).font(.callout).foregroundStyle(.red)
      }
      Divider()
      PositionsSection()
    }
  }
}

struct HeightHeader: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(model.heightCm.map { Formatting.cm($0) + " cm" } ?? "--.- cm")
        .font(.system(size: 40, weight: .semibold, design: .rounded))
        .monospacedDigit()
      Text(model.statusText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
