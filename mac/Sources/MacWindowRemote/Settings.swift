import Foundation

/// UserDefaults-backed settings (DESIGN.md D2, D5).
enum AppSettings {
    static let defaultPort = 8765
    private static let portKey = "port"
    private static let allowedLoginKey = "allowedLogin"

    static var port: Int {
        get {
            let p = UserDefaults.standard.integer(forKey: portKey)
            return (1...65535).contains(p) ? p : defaultPort
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    /// The Tailscale login allowed to connect, when set; otherwise the login this Mac is
    /// signed in with (D32).
    static var allowedLoginOverride: String {
        get { UserDefaults.standard.string(forKey: allowedLoginKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: allowedLoginKey) }
    }

    static var serveCommand: String { "tailscale serve --bg http://127.0.0.1:\(port)" }
}
