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
    /// off the main thread. Gives up after `timeout` even if a child of the CLI keeps the
    /// output pipe open: output is read as it arrives and the wait has a real deadline.
    static func queryOwnerLogin(timeout: TimeInterval = 5) -> String? {
        guard let cli = cliPath() else {
            log.notice("tailscale CLI not found")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let reader = out.fileHandleForReading
        let output = CLIOutput()
        let exited = DispatchSemaphore(value: 0)
        let endOfOutput = DispatchSemaphore(value: 0)
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                endOfOutput.signal()
            } else {
                output.append(chunk)
            }
        }
        process.terminationHandler = { _ in exited.signal() }
        // The pipe's handles close when `out` is released.
        defer { reader.readabilityHandler = nil }
        do { try process.run() } catch {
            log.notice("tailscale status could not run")
            return nil
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            log.notice("tailscale status timed out")
            return nil
        }
        // A child of the CLI may still hold the pipe open; use what arrived by then.
        _ = endOfOutput.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0, let login = ownerLogin(fromStatusJSON: output.data) else {
            log.notice("tailscale status gave no owner login")
            return nil
        }
        return login
    }
}

/// Output of one CLI run, appended from the pipe's readability handler.
private final class CLIOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) { lock.withLock { buffer.append(chunk) } }

    var data: Data { lock.withLock { buffer } }
}

/// The allowed login: the Settings override if set, else the cached CLI answer (D32).
/// - A known answer is returned at once, without running the CLI.
/// - While unknown, the CLI is asked again at most every `retryInterval`, so starting
///   Tailscale after the app works without a relaunch.
/// - `recheck()` asks again after a rejected request (at most every `retryInterval`), so a
///   wrong answer read at boot is corrected by the owner's next request.
/// - An answer older than `refreshInterval` is refreshed in the background by the next lookup.
/// - One CLI run at a time; a run that has not answered within `queryDeadline` counts as
///   unknown, so a hung CLI cannot block later lookups.
actor OwnerLogin {
    static let retryInterval: Duration = .seconds(5)
    static let refreshInterval: Duration = .seconds(60)
    static let queryDeadline: Duration = .seconds(10)

    private let override: @Sendable () -> String
    private let query: @Sendable () -> String?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let queryDeadline: Duration
    private let onChange: @Sendable () -> Void
    private var cached: String?
    private var fetchedAt: ContinuousClock.Instant?
    private var lastQuery: ContinuousClock.Instant?
    private var inFlight: (id: Int, task: Task<String?, Never>)?
    private var nextQueryID = 0

    init(override: @escaping @Sendable () -> String = { AppSettings.allowedLoginOverride },
         query: @escaping @Sendable () -> String? = { TailscaleIdentity.queryOwnerLogin() },
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         queryDeadline: Duration = OwnerLogin.queryDeadline,
         onChange: @escaping @Sendable () -> Void = {}) {
        self.override = override
        self.query = query
        self.now = now
        self.queryDeadline = queryDeadline
        self.onChange = onChange
    }

    func current() async -> String? {
        if let manual = manualLogin() { return manual }
        if let cached {
            if let fetchedAt, now() - fetchedAt >= Self.refreshInterval, inFlight == nil {
                Task { _ = await self.ask() }
            }
            return cached
        }
        guard retryDue() else { return nil }
        return await ask()
    }

    /// The allowed login after a request was rejected as another user or unknown owner: the
    /// CLI is asked again if it has not been asked within `retryInterval`.
    func recheck() async -> String? {
        if let manual = manualLogin() { return manual }
        if let inFlight { return await finish(inFlight) }
        guard retryDue() else { return cached }
        return await ask()
    }

    private func manualLogin() -> String? {
        let manual = override().trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? nil : manual
    }

    private func retryDue() -> Bool {
        guard let lastQuery else { return true }
        return now() - lastQuery >= Self.retryInterval
    }

    /// Runs the CLI (or joins the run in flight) and stores a non-nil answer. A failed run
    /// keeps the previous answer.
    private func ask() async -> String? {
        if let inFlight { return await finish(inFlight) }
        lastQuery = now()
        nextQueryID += 1
        let run = (id: nextQueryID, task: Task { [query, queryDeadline] in
            await Self.run(query, deadline: queryDeadline)
        })
        inFlight = run
        return await finish(run)
    }

    private func finish(_ run: (id: Int, task: Task<String?, Never>)) async -> String? {
        let login = await run.task.value
        guard inFlight?.id == run.id else { return cached }
        inFlight = nil
        if let login {
            fetchedAt = now()
            if login != cached {
                log.notice("owner login \(self.cached == nil ? "found" : "changed", privacy: .public): \(login, privacy: .private)")
                cached = login
                onChange()
            }
        } else {
            log.notice("owner login lookup failed known=\(self.cached != nil, privacy: .public)")
        }
        return cached
    }

    /// Calls the blocking `query` on a GCD thread, so a hung call holds no Swift concurrency
    /// thread; nil once `deadline` passes.
    private static func run(_ query: @escaping @Sendable () -> String?, deadline: Duration) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .utility).async { once.resume(query()) }
            let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.resume(nil) { log.notice("owner login lookup timed out") }
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    @discardableResult
    func resume(_ value: String?) -> Bool {
        let pending: CheckedContinuation<String?, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
        return pending != nil
    }
}
