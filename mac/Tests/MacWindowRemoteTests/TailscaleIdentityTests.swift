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
}
