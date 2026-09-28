import Foundation
import Testing
@testable import MacWindowRemote

@Suite struct PairingSecretTests {
    @Test func generatedSecretIs256BitBase64url() {
        let a = PairingSecret.generate()
        let b = PairingSecret.generate()
        #expect(a != b)
        #expect(a.count == 43) // 32 bytes, unpadded base64
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func compare() {
        let s = PairingSecret.generate()
        #expect(PairingSecret.matches(s, s))
        #expect(!PairingSecret.matches(String(s.dropLast()), s))
        #expect(!PairingSecret.matches(s + "x", s))
        #expect(!PairingSecret.matches("", s))
        #expect(!PairingSecret.matches("", ""))
        var flipped = Array(s)
        flipped[0] = flipped[0] == "A" ? "B" : "A"
        #expect(!PairingSecret.matches(String(flipped), s))
    }

    @Test func storeKeepsTheSecretOwnerOnlyAndReplacesItOnReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mwr-secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PairingSecretStore(directory: root.appendingPathComponent("mac-window-remote"))

        let first = try store.loadOrCreate()
        #expect(try store.loadOrCreate() == first) // later launches keep pairing
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int) == 0o700)
        #expect((try fm.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int) == 0o600)

        let second = try store.reset()
        #expect(second != first)
        #expect(try store.loadOrCreate() == second)
        #expect((try fm.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int) == 0o600)
        // Only the secret file remains; no temporary files are left behind.
        #expect(try fm.contentsOfDirectory(atPath: store.directory.path) == [PairingSecretStore.fileName])
    }
}
