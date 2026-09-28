import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Setup & Permissions (DESIGN.md D16)

struct SetupView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("mac-window-remote needs two permissions to show and operate windows from your iPhone.")
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                title: "Screen Recording",
                detail: "Lets the app capture the window you pick.",
                granted: state.permissions.screenRecording,
                request: {
                    Permissions.requestScreenRecording()
                    state.screenRecordingRequested = true
                },
                openSettings: Permissions.openScreenRecordingSettings)
            if !state.permissions.screenRecording {
                HStack {
                    Text(state.screenRecordingRequested
                         ? "Relaunch required: after allowing the app in System Settings, relaunch it."
                         : "After allowing the app in System Settings, relaunch it so macOS applies the permission.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Relaunch") { Permissions.relaunch() }
                }
            }

            PermissionRow(
                title: "Accessibility",
                detail: "Lets the app click and type in the window.",
                granted: state.permissions.accessibility,
                request: Permissions.requestAccessibility,
                openSettings: Permissions.openAccessibilitySettings)

            Divider()

            ServeCommandView()
            Text("Then open the https address that `tailscale serve` prints in Safari on an iPhone signed in to Tailscale as the allowed user.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            AllowedLoginField(state: state)
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Text(granted ? "✅" : "⚠️")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Request", action: request)
                Button("Open Settings", action: openSettings)
            } else {
                Text("Granted").foregroundStyle(.secondary)
            }
        }
    }
}

struct ServeCommandView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Run once in Terminal to expose the page inside your tailnet over HTTPS:")
                .font(.callout)
            HStack {
                Text(AppSettings.serveCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { copyToPasteboard(AppSettings.serveCommand) }
            }
        }
    }
}

/// Who may connect (D32): the Tailscale login this Mac is signed in with, or an override.
struct AllowedLoginField: View {
    @ObservedObject var state: AppState
    @State private var override = AppSettings.allowedLoginOverride

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Allowed Tailscale login. Only this tailnet user can open the page:").font(.callout)
            TextField(state.allowedLogin ?? "Sign in to Tailscale on this Mac", text: $override)
                .textFieldStyle(.roundedBorder)
                .onChange(of: override) { _, value in
                    AppSettings.allowedLoginOverride = value
                    state.refreshAllowedLogin()
                }
            Text("Leave empty to allow the login this Mac is signed in with.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings (DESIGN.md D2, D5, D17)

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var portText = String(AppSettings.port)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            HStack {
                TextField("Port", text: $portText)
                    .frame(width: 160)
                Button("Apply") {
                    guard let p = Int(portText), (1024...65535).contains(p) else {
                        portText = String(AppSettings.port)
                        return
                    }
                    if p != AppSettings.port {
                        AppSettings.port = p
                        state.startServer()
                    }
                }
            }
            Text("The server listens on 127.0.0.1 only. If you change the port, run `tailscale serve` again with the new port.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AllowedLoginField(state: state)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = "Could not change login item: \(error.localizedDescription)"
                    }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
        }
        .padding(20)
        .frame(width: 460)
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
