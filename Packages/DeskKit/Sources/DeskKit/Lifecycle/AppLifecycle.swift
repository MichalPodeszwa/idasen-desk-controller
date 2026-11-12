import AppKit

@MainActor
public final class AppLifecycle {
  public static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")

  private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

  public init(
    center: NotificationCenter = .default,
    workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
    endHold: @escaping @MainActor () -> Void,
    prepareForSleep: @escaping @MainActor () -> Void,
    handleWake: @escaping @MainActor () -> Void
  ) {
    observe(center, NSWindow.didResignKeyNotification, endHold)
    observe(center, NSWindow.willCloseNotification, endHold)
    observe(center, NSApplication.didResignActiveNotification, endHold)
    observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, endHold)
    observe(workspaceCenter, NSWorkspace.screensDidSleepNotification, endHold)
    observe(distributedCenter, Self.screenLockedNotification, endHold)
    observe(workspaceCenter, NSWorkspace.willSleepNotification, prepareForSleep)
    observe(workspaceCenter, NSWorkspace.didWakeNotification, handleWake)
  }

  public func invalidate() {
    for observer in observers {
      observer.center.removeObserver(observer.token)
    }
    observers = []
  }

  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name,
    _ handler: @escaping @MainActor () -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
      DeskLog.app.info("lifecycle notification: \(name.rawValue, privacy: .public)")
      MainActor.assumeIsolated(handler)
    }
    observers.append((center, token))
  }
}
