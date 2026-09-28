import Foundation

/// Authentication by Tailscale identity (DESIGN.md D32). `tailscale serve` adds
/// `Tailscale-User-Login` to every request it proxies from a signed-in tailnet user; only the
/// Mac owner's login is allowed. Requests without the header (direct local access, tagged
/// devices) or with another login are rejected.
enum TailscaleIdentity {
    static let loginHeader = "Tailscale-User-Login"
    /// Shown on the phone for a rejected request (HTTP 403 body; the page shows the same text
    /// for close code 4001).
    static let notAllowedMessage = "Not allowed: sign in to Tailscale as the Mac owner"

    enum Decision: Equatable {
        case allowed
        /// The request came without the header: not through `tailscale serve`, or from a
        /// tagged device, which has no user login.
        case missingHeader
        /// Another tailnet user.
        case otherUser
        /// The owner login is unknown (Tailscale not running or not signed in, and no override).
        case ownerUnknown
    }

    /// Tailnet logins are email-like and compared case-insensitively.
    static func check(header: String?, owner: String?) -> Decision {
        guard let owner = normalized(owner) else { return .ownerUnknown }
        guard let login = normalized(header) else { return .missingHeader }
        return login == owner ? .allowed : .otherUser
    }

    private static func normalized(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !t.isEmpty else { return nil }
        return t
    }

    /// The signed-in user of this Mac from `tailscale status --json`: `Self.UserID` looked up
    /// in `User`.
    static func ownerLogin(fromStatusJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = root["Self"] as? [String: Any],
              let userID = me["UserID"] as? NSNumber,
              let users = root["User"] as? [String: Any],
              let user = users[userID.stringValue] as? [String: Any],
              let login = user["LoginName"] as? String, !login.isEmpty
        else { return nil }
        return login
    }

    /// The Tailscale CLI: the Mac app bundle first (App Store and standalone builds), then
    /// the usual Homebrew and open-source install paths.
    static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static func cliPath() -> String? {
        let fm = FileManager.default
        if let found = cliCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/tailscale"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs `tailscale status --json` and returns the owner login, or nil. Blocking; call it
    /// off the main thread. Gives up after `timeout`.
    static func queryOwnerLogin(timeout: TimeInterval = 5) -> String? {
        guard let cli = cliPath() else {
            log.info("tailscale CLI not found")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            log.info("tailscale status could not run")
            return nil
        }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let login = ownerLogin(fromStatusJSON: data) else {
            log.info("tailscale status gave no owner login")
            return nil
        }
        return login
    }
}

/// The allowed login: the Settings override if set, else the cached CLI answer. The CLI is
/// asked again (at most every `refreshInterval`) while the answer is unknown, so starting
/// Tailscale after the app works without a relaunch.
actor OwnerLogin {
    static let refreshInterval: Duration = .seconds(30)

    private let override: @Sendable () -> String
    private let query: @Sendable () -> String?
    private var cached: String?
    private var lastQuery: ContinuousClock.Instant?

    init(override: @escaping @Sendable () -> String = { AppSettings.allowedLoginOverride },
         query: @escaping @Sendable () -> String? = { TailscaleIdentity.queryOwnerLogin() }) {
        self.override = override
        self.query = query
    }

    func current() async -> String? {
        let manual = override().trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        if let cached { return cached }
        let now = ContinuousClock.now
        if let lastQuery, now - lastQuery < Self.refreshInterval { return nil }
        lastQuery = now
        let query = query
        cached = await Task.detached { query() }.value
        return cached
    }
}
