import Foundation

/// UserDefaults-backed settings (DESIGN.md D2, D5).
enum AppSettings {
    static let defaultPort = 8765
    private static let portKey = "port"
    private static let iPhoneURLKey = "iPhoneURL"

    static var port: Int {
        get {
            let p = UserDefaults.standard.integer(forKey: portKey)
            return (1...65535).contains(p) ? p : defaultPort
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    /// Base URL of the page as served by `tailscale serve`, used only to build the pairing QR.
    static var iPhoneURL: String {
        get { UserDefaults.standard.string(forKey: iPhoneURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: iPhoneURLKey) }
    }

    static var serveCommand: String { "tailscale serve --bg http://127.0.0.1:\(port)" }

    static func pairingURL(secret: String) -> String? {
        var base = iPhoneURL
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/#pair=\(secret)"
    }
}
