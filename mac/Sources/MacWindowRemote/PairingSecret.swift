import Darwin
import Foundation

/// The single pairing secret (DESIGN.md D6): 32 random bytes, base64url, kept in a file that
/// only the user can read. It is never logged.
enum PairingSecret {
    static func generate() -> String {
        // SystemRandomNumberGenerator is the system CSPRNG (arc4random_buf) on Apple platforms.
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
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
}

/// Where the pairing secret lives: `<directory>/pairing-secret`, directory 0700, file 0600,
/// replaced atomically (D6). The app uses `default`; tests pass a temporary directory.
struct PairingSecretStore: Sendable {
    let directory: URL

    static let fileName = "pairing-secret"

    /// `~/Library/Application Support/mac-window-remote`.
    static var `default`: PairingSecretStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PairingSecretStore(directory: support.appendingPathComponent("mac-window-remote", isDirectory: true))
    }

    enum Failure: Error {
        case io(String, Int32)
    }

    var file: URL { directory.appendingPathComponent(Self.fileName) }

    /// The stored secret, or a new one stored on first launch.
    func loadOrCreate() throws -> String {
        if let data = try? Data(contentsOf: file),
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return try reset()
    }

    /// "Reset pairing": a new secret replaces the file.
    func reset() throws -> String {
        let secret = PairingSecret.generate()
        try write(secret)
        return secret
    }

    private func write(_ secret: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw Failure.io("chmod directory", errno) }
        // The temporary file is created 0600, so the secret is never readable by others, and
        // rename(2) replaces the old file atomically.
        let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure.io("open", errno) }
        let bytes = Array(secret.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd)
        close(fd)
        guard written == bytes.count, synced == 0 else {
            unlink(temporary.path)
            throw Failure.io("write", errno)
        }
        guard rename(temporary.path, file.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw Failure.io("rename", code)
        }
    }
}
