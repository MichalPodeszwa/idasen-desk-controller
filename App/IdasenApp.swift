import AppKit
import SwiftUI

@main
struct IdasenApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra {
      PopoverView()
        .environment(AppModel.shared)
    } label: {
      MenuBarLabel()
        .environment(AppModel.shared)
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var signalSources: [any DispatchSourceSignal] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    for signalNumber in [SIGTERM, SIGINT] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler {
        RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
      }
      source.resume()
      signalSources.append(source)
    }
    Task { await AppModel.shared.launch() }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if AppModel.shared.skipsShutdown { return .terminateNow }
    AppModel.shared.prepareToTerminate {
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
