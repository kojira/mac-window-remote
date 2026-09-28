import AppKit
import Hummingbird
import ServiceManagement
import SwiftUI

@main
struct MacWindowRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(nsImage: MenuBarIcon.image(viewing: state.isViewing, warning: !state.permissionsOK))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.launch() }
    }
}

// MARK: - State

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var permissions = Permissions.status
    @Published private(set) var connection: ConnectionStatus = .idle
    @Published private(set) var serverError: String?
    /// The login allowed to connect (D32), for the menu; nil while unknown.
    @Published private(set) var allowedLogin: String?
    /// Set once the user asked for Screen Recording in this run; a grant applies only after relaunch.
    @Published var screenRecordingRequested = false

    private var hub: SessionHub?
    private var serverTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private let windows = WindowPresenter()

    var permissionsOK: Bool { permissions.screenRecording && permissions.accessibility }
    var isViewing: Bool { if case .viewing = connection { return true } else { return false } }

    var statusLine: String {
        if let serverError { return serverError }
        if !permissionsOK { return "Permissions needed" }
        switch connection {
        case .idle: return "Idle"
        case .connected: return "Connected"
        case .viewing(let app, let title): return "Viewing: \(app) — \(title.isEmpty ? "(untitled)" : title)"
        }
    }

    private let owner = OwnerLogin()

    func launch() {
        RTCHost.initialize()
        let backend = MacBackend(rtc: RTCHost(), onViewing: { _ in })
        hub = SessionHub(owner: owner, backend: backend, onStatus: { status in
            Task { @MainActor in AppState.shared.connection = status }
        })
        startServer()
        refreshAllowedLogin()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppState.shared.refreshPermissions() }
        }
        let firstLaunchKey = "setupShown"
        if !permissionsOK || !UserDefaults.standard.bool(forKey: firstLaunchKey) {
            UserDefaults.standard.set(true, forKey: firstLaunchKey)
            showSetup()
        }
    }

    func refreshPermissions() {
        let now = Permissions.status
        if now != permissions { permissions = now }
        if allowedLogin == nil { refreshAllowedLogin() }
    }

    /// Reads the allowed login for the menu. `OwnerLogin` asks the Tailscale CLI at most every
    /// 30 s while the login is unknown.
    func refreshAllowedLogin() {
        let owner = owner
        Task {
            let login = await owner.current()
            if login != allowedLogin { allowedLogin = login }
        }
    }

    func startServer() {
        guard let hub else { return }
        serverTask?.cancel()
        let previous = serverTask
        let port = AppSettings.port
        serverError = nil
        serverTask = Task.detached {
            await previous?.value
            let app = Server.makeApplication(port: port, webRoot: Server.webRoot(), hub: hub)
            do {
                try await app.run()
            } catch {
                log.error("server failed on port \(port, privacy: .public): \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    AppState.shared.serverError = "Server not running (port \(port) in use?)"
                }
            }
        }
    }

    func showSetup() { windows.show(.setup) { SetupView(state: self) } }
    func showSettings() { windows.show(.settings) { SettingsView(state: self) } }
}

// MARK: - Menu

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.statusLine)
        Text(state.allowedLogin.map { "Allowed: \($0)" } ?? "Allowed: unknown (sign in to Tailscale)")
        Divider()
        Button("Setup & Permissions…") { state.showSetup() }
        Button("Settings…") { state.showSettings() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

enum MenuBarIcon {
    /// `rectangle.on.rectangle`, filled while a client is viewing, with a warning badge while a
    /// permission is missing (DESIGN.md D19).
    static func image(viewing: Bool, warning: Bool) -> NSImage {
        let name = viewing ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "mac-window-remote") ?? NSImage()
        guard warning,
              let badge = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Permissions needed")
        else {
            base.isTemplate = true
            return base
        }
        let size = NSSize(width: base.size.width + 8, height: max(base.size.height, 16))
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: (size.height - base.size.height) / 2, width: base.size.width, height: base.size.height))
            badge.draw(in: NSRect(x: size.width - 10, y: 0, width: 10, height: 10))
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Windows

@MainActor
final class WindowPresenter {
    enum Kind: String { case setup, settings }
    private var open: [Kind: NSWindow] = [:]

    func show<V: View>(_ kind: Kind, @ViewBuilder content: () -> V) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = open[kind] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
        w.title = switch kind {
        case .setup: "Setup & Permissions"
        case .settings: "Settings"
        }
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        open[kind] = w
    }
}
