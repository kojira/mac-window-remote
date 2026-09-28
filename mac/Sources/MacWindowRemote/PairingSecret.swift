import Foundation
import Security

/// The single pairing secret (DESIGN.md D6): 32 random bytes, base64url, kept in the Keychain.
/// It is never logged.
enum PairingSecret {
    static let keychainService = "mac-window-remote"
    static let keychainAccount = "pairing-secret"

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64url(Data(bytes))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time comparison: the running time depends only on the lengths, not on where
    /// the inputs first differ.
    static func matches(_ candidate: String, _ expected: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(expected.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<b.count {
            let x = i < a.count ? a[i] : 0
            diff |= x ^ b[i]
        }
        return diff == 0 && !b.isEmpty
    }

    // MARK: Keychain

    static func loadOrCreate() -> String {
        if let existing = load() { return existing }
        let secret = generate()
        store(secret)
        return secret
    }

    static func reset() -> String {
        let secret = generate()
        store(secret)
        return secret
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    private static func store(_ secret: String) {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
