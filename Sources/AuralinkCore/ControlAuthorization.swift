import Foundation

/// Authentication shared by the app's loopback HTTP server and local clients.
///
/// Loopback binding prevents access from another machine, but it does not stop
/// a browser tab or unrelated process running as the same user from calling the
/// port. A random bearer token stored in the user's Application Support folder
/// provides that missing capability boundary without requiring an account.
public enum ControlAuthorization {
    public static let tokenEnvironmentVariable = "AURALINK_CONTROL_TOKEN"
    public static let tokenFileEnvironmentVariable = "AURALINK_CONTROL_TOKEN_FILE"
    public static let minimumTokenLength = 32

    /// Returns an explicit environment token or loads/creates the shared token
    /// file. Tokens contain only bearer-safe characters and at least 256 bits of
    /// UUID-derived randomness when generated here.
    public static func loadOrCreateToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) throws -> String {
        if let explicit = normalizedToken(environment[tokenEnvironmentVariable]) {
            return explicit
        }

        let resolvedFileURL: URL
        if let fileURL {
            resolvedFileURL = fileURL
        } else if let override = environment[tokenFileEnvironmentVariable], !override.isEmpty {
            resolvedFileURL = URL(fileURLWithPath: override)
        } else {
            resolvedFileURL = AuralinkPaths.controlTokenFile
        }

        let fm = FileManager.default
        let parent = resolvedFileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        if let raw = try? String(contentsOf: resolvedFileURL, encoding: .utf8),
           let existing = normalizedToken(raw) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolvedFileURL.path)
            return existing
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try Data("\(token)\n".utf8).write(to: resolvedFileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolvedFileURL.path)
        return token
    }

    /// Validates an HTTP Authorization header without an early-exit comparison.
    public static func isAuthorized(headers: [String: String], token: String) -> Bool {
        guard let authorization = headers.first(where: {
            $0.key.caseInsensitiveCompare("authorization") == .orderedSame
        })?.value else {
            return false
        }
        let pieces = authorization.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2,
              pieces[0].caseInsensitiveCompare("bearer") == .orderedSame else {
            return false
        }
        return constantTimeEqual(String(pieces[1]), token)
    }

    public static func normalizedToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count >= minimumTokenLength,
              token.unicodeScalars.allSatisfy(isBearerSafeASCII) else {
            return nil
        }
        return token
    }

    private static func isBearerSafeASCII(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122, 45, 46, 95, 126:
            return true
        default:
            return false
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}
