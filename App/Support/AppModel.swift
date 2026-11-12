import AppKit
import CoreBluetooth
import DeskIPC
import DeskKit
import DeskServer
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
  static let shared = AppModel()

  static let simulateFlag = "--simulate"
  static let simulateVariable = "IDASEN_SIMULATE"
  static let shutdownTimeout = Duration.seconds(2)

  let isSimulated: Bool
  let hardwareOptions: HardwareOptions
  let settings: AppSettings
  let controller: DeskController

  private(set) var needsExplanation = false
  private(set) var serverProblem: String?
  private(set) var launchAtLogin = false
  private(set) var cliStatus = CLIInstaller.Status.notInstalled
  var notice: String?
  var settingsNotice: String?

  @ObservationIgnored private let bluetooth: CoreBluetoothTransport?
  @ObservationIgnored private let server: ControlServer
  @ObservationIgnored private var lifecycle: AppLifecycle?
  private(set) var cliPathCheck = CLIPathCheck.unknown
  @ObservationIgnored private(set) var skipsShutdown = false

  private init() {
    let arguments = CommandLine.arguments
    let environment = ProcessInfo.processInfo.environment
    let simulated =
      arguments.contains(Self.simulateFlag) || environment[Self.simulateVariable] == "1"
    isSimulated = simulated

    let options = HardwareOptions(defaults: .standard)
    hardwareOptions = options
    DeskLog.app.notice(
      "launch: bundle=\(DeskLog.subsystem, privacy: .public) path=\(Bundle.main.bundleURL.path, privacy: .public) version=\(Self.versionDescription, privacy: .public) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public) simulated=\(simulated) holdVariant=\(options.holdVariant.label, privacy: .public) dpgPatchesUserID=\(options.patchesUserID) bluetoothAuthorization=\(CoreBluetoothTransport.authorization.label, privacy: .public)"
    )

    let transport: any DeskTransport
    if simulated {
      bluetooth = nil
      transport = SimulatedDeskTransport()
      settings = AppSettings(defaults: nil)
    } else {
      let real = CoreBluetoothTransport(
        settings: UserDefaultsDeskSettings(), patchesUserID: options.patchesUserID)
      bluetooth = real
      transport = real
      settings = AppSettings(defaults: .standard)
    }
    let positions = PositionStore(directory: SocketPath.supportDirectory())
    let controller = DeskController(transport: transport, positions: positions)
    self.controller = controller
    let settings = settings
    server = ControlServer(desk: controller, calibrationMM: { settings.calibrationMM })
    refreshInstallState()
  }

  var baseMM: Double {
    controller.baseMM
  }

  var minCm: Double {
    DeskHeight(clamping: DeskHeight.range.lowerBound).cm(
      baseMM: baseMM, calibrationMM: settings.calibrationMM)
  }

  var maxCm: Double {
    DeskHeight(clamping: DeskHeight.range.upperBound).cm(
      baseMM: baseMM, calibrationMM: settings.calibrationMM)
  }

  var rangeText: String {
    "\(Formatting.cm(minCm))–\(Formatting.cm(maxCm)) cm"
  }

  var heightCm: Double? {
    controller.heightRaw.map(cm(forRaw:))
  }

  var isConnected: Bool {
    if case .connected = controller.state { return true }
    return false
  }

  var isMoving: Bool {
    if case .connected(.moving) = controller.state { return true }
    return false
  }

  var statusText: String {
    Formatting.status(for: controller.state, notFoundHint: controller.notFoundHint)
  }

  var authorizationLabel: String {
    isSimulated ? "not used (simulated desk)" : CoreBluetoothTransport.authorization.label
  }

  var locationRefusal: String? {
    InstallLocation.refusal(bundleURL: Bundle.main.bundleURL)
  }

  var cliLinkPath: String {
    cliInstaller.linkURL.path
  }

  private var cliInstaller: CLIInstaller {
    CLIInstaller(
      helperURL: Bundle.main.bundleURL.appending(path: "Contents/Helpers/idasen"))
  }

  func cm(forRaw raw: Int) -> Double {
    DeskHeight(clamping: raw).cm(baseMM: baseMM, calibrationMM: settings.calibrationMM)
  }

  func launch() async {
    do throws(ControlServer.StartError) {
      try await server.start()
    } catch {
      if error == .alreadyRunning {
        skipsShutdown = true
        NSApp.terminate(nil)
        return
      }
      if error == .stopped { return }
      serverProblem = "The idasen command is unavailable: \(error)"
    }
    lifecycle = AppLifecycle(
      endHold: { [weak self] in self?.endHold() },
      prepareForSleep: { [weak self] in
        guard let self else { return }
        Task { await self.controller.prepareForSleep() }
      },
      handleWake: { [weak self] in self?.controller.handleWake() })
    beginConnecting()
  }

  func acceptExplanation() {
    DeskLog.app.notice("first run: explanation accepted, activating Bluetooth")
    needsExplanation = false
    bluetooth?.activate()
    controller.connect()
  }

  func connect() {
    controller.connect()
  }

  func connect(to desk: DiscoveredDesk) {
    controller.connect(to: desk.id)
  }

  func forgetDesk() {
    DeskLog.app.notice("UI: forget desk")
    Task {
      await controller.forgetDesk()
      controller.connect()
    }
  }

  func prepareToTerminate(reply: @escaping @MainActor () -> Void) {
    DeskLog.app.notice("terminating: stopping the desk and the control server")
    let gate = ShutdownGate(server: server, reply: reply)
    Task {
      await controller.stop()
      gate.finish()
    }
    Task {
      try? await Task.sleep(for: Self.shutdownTimeout)
      gate.finish()
    }
  }

  func moveTo(cm: Double) {
    guard
      let height = DeskHeight(cm: cm, baseMM: baseMM, calibrationMM: settings.calibrationMM)
    else {
      notice = "Out of range. Allowed: \(rangeText)"
      return
    }
    DeskLog.app.notice("UI: move to \(cm) cm (raw \(height.raw))")
    start { try controller.startMove(toRaw: height.raw) }
  }

  func move(to position: Position) {
    DeskLog.app.notice("UI: move to a position (raw \(position.height.raw))")
    start { try controller.startMove(toPositionID: position.id) }
  }

  func beginHold(_ direction: MoveDirection) {
    let variant = hardwareOptions.holdVariant
    DeskLog.app.notice(
      "UI: hold begin direction=\(String(describing: direction), privacy: .public) variant=\(variant.label, privacy: .public)"
    )
    start { try controller.beginHold(direction, input: MouseHoldInput(), variant: variant) }
  }

  func endHold() {
    Task { await controller.endHold() }
  }

  func stop() {
    DeskLog.app.notice("UI: stop")
    notice = nil
    Task { await controller.stop() }
  }

  func savePosition(named name: String, heightText: String) -> String? {
    var raw: Int?
    if !heightText.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let cm = HeightInput.parse(heightText),
        let height = DeskHeight(cm: cm, baseMM: baseMM, calibrationMM: settings.calibrationMM)
      else { return "Enter a height between \(rangeText)" }
      raw = height.raw
    }
    do throws(DeskControllerError) {
      try controller.savePosition(named: name, raw: raw)
      return nil
    } catch {
      return Formatting.message(for: error)
    }
  }

  func rename(_ position: Position, to name: String) -> String? {
    guard PositionName.normalized(name) != position.name else { return nil }
    return storeAction { try controller.positions.rename(id: position.id, to: name) }
  }

  func setHeight(_ position: Position, cm: Double) -> String? {
    guard
      let height = DeskHeight(cm: cm, baseMM: baseMM, calibrationMM: settings.calibrationMM)
    else { return "Enter a height between \(rangeText)" }
    guard height != position.height else { return nil }
    return storeAction { try controller.positions.updateHeight(id: position.id, to: height) }
  }

  func remove(_ position: Position) -> String? {
    storeAction { try controller.positions.remove(id: position.id) }
  }

  func reorder(_ position: Position, toIndex index: Int) -> String? {
    storeAction { try controller.positions.move(id: position.id, toIndex: index) }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    settingsNotice = nil
    if let refusal = locationRefusal {
      settingsNotice = refusal
      refreshInstallState()
      return
    }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      settingsNotice = "Launch at login failed: \(error.localizedDescription)"
    }
    refreshInstallState()
  }

  func installCLI() {
    settingsNotice = nil
    if let refusal = locationRefusal {
      settingsNotice = refusal
      return
    }
    do throws(CLIInstaller.InstallError) {
      try cliInstaller.install()
    } catch {
      settingsNotice = Self.message(for: error)
    }
    refreshInstallState()
    Task { await checkCLIPath() }
  }

  func uninstallCLI() {
    settingsNotice = nil
    do throws(CLIInstaller.InstallError) {
      try cliInstaller.uninstall()
    } catch {
      settingsNotice = Self.message(for: error)
    }
    refreshInstallState()
  }

  func checkCLIPath() async {
    guard cliStatus == .installed else {
      cliPathCheck = .unknown
      return
    }
    guard let path = await LoginShellPath.resolve() else {
      cliPathCheck = .unavailable
      return
    }
    cliPathCheck = cliInstaller.isOnPath(path) ? .onPath : .missing
  }

  func refreshInstallState() {
    launchAtLogin = SMAppService.mainApp.status == .enabled
    cliStatus = cliInstaller.status()
  }

  private func beginConnecting() {
    guard let bluetooth else {
      controller.connect()
      return
    }
    if CoreBluetoothTransport.authorization == .notDetermined {
      DeskLog.app.notice("first run: Bluetooth authorization not determined, showing explanation")
      needsExplanation = true
      return
    }
    bluetooth.activate()
    controller.connect()
  }

  private func start(_ begin: () throws -> MoveTicket) {
    notice = nil
    let ticket: MoveTicket
    do {
      ticket = try begin()
    } catch {
      DeskLog.app.notice("UI: command refused: \(String(describing: error), privacy: .public)")
      notice = Formatting.message(for: error)
      return
    }
    Task {
      if case .failure(let error) = await ticket.result(), error != .interrupted {
        DeskLog.app.notice(
          "UI: move #\(ticket.id.rawValue) failed: \(String(describing: error), privacy: .public)")
        notice = Formatting.message(for: error)
      }
    }
  }

  private func storeAction(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch {
      return Formatting.message(for: error)
    }
  }

  private static var versionDescription: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
  }

  private static func message(for error: CLIInstaller.InstallError) -> String {
    switch error {
    case .blockedByFile(let path): "\(path) already exists and is not a symlink"
    case .failed(let detail): "Could not update the symlink: \(detail)"
    }
  }
}

enum CLIPathCheck {
  case unknown
  case onPath
  case missing
  case unavailable
}

@MainActor
private final class ShutdownGate {
  private let server: ControlServer
  private let reply: @MainActor () -> Void
  private var finished = false

  init(server: ControlServer, reply: @escaping @MainActor () -> Void) {
    self.server = server
    self.reply = reply
  }

  func finish() {
    guard !finished else { return }
    finished = true
    server.stop()
    reply()
  }
}
