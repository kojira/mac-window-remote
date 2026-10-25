import Foundation
import Testing
@testable import MacWindowRemote

@Suite struct TailscaleIdentityTests {
    @Test func headerCheck() {
        let owner = "owner@example.com"
        #expect(TailscaleIdentity.check(header: owner, owner: owner) == .allowed)
        #expect(TailscaleIdentity.check(header: "OWNER@example.com ", owner: owner) == .allowed)
        #expect(TailscaleIdentity.check(header: "someone@example.com", owner: owner) == .otherUser)
        #expect(TailscaleIdentity.check(header: nil, owner: owner) == .missingHeader)
        #expect(TailscaleIdentity.check(header: "", owner: owner) == .missingHeader)
        // Without a known owner, nobody is allowed.
        #expect(TailscaleIdentity.check(header: owner, owner: nil) == .ownerUnknown)
        #expect(TailscaleIdentity.check(header: owner, owner: " ") == .ownerUnknown)
    }

    /// The shape of `tailscale status --json`, trimmed, with fake values.
    @Test func ownerLoginFromStatusJSON() {
        let status = #"""
        {
          "BackendState": "Running",
          "Self": { "ID": "nFAKE", "HostName": "fake-mac", "UserID": 222, "TailscaleIPs": [] },
          "Peer": { "nodekey:fake": { "HostName": "fake-phone", "UserID": 111 } },
          "User": {
            "111": { "ID": 111, "LoginName": "other@example.com", "DisplayName": "Other" },
            "222": { "ID": 222, "LoginName": "owner@example.com", "DisplayName": "Owner" }
          }
        }
        """#
        #expect(TailscaleIdentity.ownerLogin(fromStatusJSON: Data(status.utf8)) == "owner@example.com")
        // Logged out: no Self user.
        let loggedOut = #"{"BackendState":"NeedsLogin","Self":{"UserID":0},"User":null}"#
        #expect(TailscaleIdentity.ownerLogin(fromStatusJSON: Data(loggedOut.utf8)) == nil)
        #expect(TailscaleIdentity.ownerLogin(fromStatusJSON: Data("not json".utf8)) == nil)
    }

    @Test func overrideWinsOverTheCLI() async {
        let owner = OwnerLogin(override: { " manual@example.com " }, query: { "cli@example.com" })
        #expect(await owner.current() == "manual@example.com")
        let fromCLI = OwnerLogin(override: { "" }, query: { "cli@example.com" })
        #expect(await fromCLI.current() == "cli@example.com")
    }

    @Test func unknownIsRetried() async {
        let clock = FakeClock()
        let cli = FakeCLI([nil, "owner@example.com"])
        let owner = OwnerLogin(override: { "" }, query: cli.query, now: clock.now)
        #expect(await owner.current() == nil)
        #expect(await owner.current() == nil)
        #expect(cli.calls == 1)
        clock.advance(.seconds(5))
        #expect(await owner.current() == "owner@example.com")
        #expect(cli.calls == 2)
    }

    @Test func hungQueryDoesNotBlockLaterLookups() async {
        let clock = FakeClock()
        let release = DispatchSemaphore(value: 0)
        let cli = FakeCLI(["owner@example.com"], hangFirst: release)
        let owner = OwnerLogin(override: { "" }, query: cli.query, now: clock.now, queryDeadline: .milliseconds(100))
        #expect(await owner.current() == nil)
        clock.advance(.seconds(5))
        #expect(await owner.current() == "owner@example.com")
        #expect(cli.calls == 2)
        release.signal()
    }
}

/// A clock the test moves by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: @Sendable () -> ContinuousClock.Instant { { self.lock.withLock { self.instant } } }
    func advance(_ by: Duration) { lock.withLock { instant += by } }
}

/// `tailscale status` answers in order (the last one repeats); optionally the first call hangs.
final class FakeCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String?]
    private var count = 0
    private let hangFirst: DispatchSemaphore?

    init(_ answers: [String?], hangFirst: DispatchSemaphore? = nil) {
        self.answers = answers
        self.hangFirst = hangFirst
    }

    var calls: Int { lock.withLock { count } }

    var query: @Sendable () -> String? {
        {
            let n = self.lock.withLock { self.count += 1; return self.count }
            if n == 1, let hang = self.hangFirst { hang.wait(); return "late@example.com" }
            return self.lock.withLock { self.answers.count > 1 ? self.answers.removeFirst() : self.answers.first ?? nil }
        }
    }
}
