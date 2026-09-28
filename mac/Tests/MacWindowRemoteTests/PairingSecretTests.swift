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
}
