import AppKit
import CoreImage.CIFilterBuiltins
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
            IPhoneURLField()

            HStack {
                Spacer()
                Button("Pair iPhone…") { state.showPair() }
            }
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

struct IPhoneURLField: View {
    @State private var url = AppSettings.iPhoneURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("iPhone URL (the https address that `tailscale serve` prints):").font(.callout)
            TextField("https://your-mac.your-tailnet.ts.net", text: $url)
                .textFieldStyle(.roundedBorder)
                .onChange(of: url) { _, value in AppSettings.iPhoneURL = value }
        }
    }
}

// MARK: - Pair iPhone (DESIGN.md D6)

struct PairView: View {
    @ObservedObject var state: AppState
    @State private var iPhoneURL = AppSettings.iPhoneURL

    var body: some View {
        VStack(spacing: 14) {
            if let url = AppSettings.pairingURL(secret: state.secret), let qr = QRCode.image(for: url) {
                Text("Scan with the iPhone camera, then open the link in Safari.")
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
            } else {
                Text("Set the iPhone URL first, so the QR code can point to your Mac.")
                    .foregroundStyle(.orange)
                IPhoneURLField()
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing code (paste it on the iPhone, e.g. in a Home Screen web app):").font(.callout)
                HStack {
                    Text(state.secret)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Copy") { copyToPasteboard(state.secret) }
                }
            }
            Text("Anyone with this code can control this Mac through your tailnet. Use Reset pairing in the menu to revoke it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Re-render when the iPhone URL is entered in another window.
            if iPhoneURL != AppSettings.iPhoneURL { iPhoneURL = AppSettings.iPhoneURL }
        }
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
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
            IPhoneURLField()
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
