import Foundation

public enum CollectionManifestError: Error, LocalizedError {
    case corrupt(url: URL, underlying: Error)
    case writeFailed(url: URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let url, let underlying):
            return "Collection manifest at \(url.path) is corrupt or from a newer build: \(underlying.localizedDescription)"
        case .writeFailed(let url, let underlying):
            return "Failed to write collection manifest at \(url.path): \(underlying.localizedDescription)"
        }
    }
}

/// Metadata for a user-owned headphone/preset collection.
///
/// The collection lives in its own directory (often a git checkout) and evolves on
/// its own schedule, so it carries a schema version the app can compare against
/// what it understands. Without this, a collection written by a newer Auralink
/// would silently half-load in an older one.
public struct CollectionManifest: Codable, Equatable, Sendable {
    /// Schema this build reads and writes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var createdAt: Date

    public init(schemaVersion: Int = CollectionManifest.currentSchemaVersion,
                name: String = "My Auralink Collection",
                createdAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.createdAt = createdAt
    }

    /// A collection written by a newer Auralink than this one.
    public var isFromNewerBuild: Bool {
        schemaVersion > CollectionManifest.currentSchemaVersion
    }

    // MARK: - Persistence

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (enc, dec)
    }

    /// Reads the manifest at `url`.
    /// - Returns: The manifest if readable, `nil` if the file doesn't exist
    /// - Throws: `CollectionManifestError.corrupt` if the file exists but cannot be decoded
    public static func read(from url: URL) -> Result<CollectionManifest?, CollectionManifestError> {
        guard let data = try? Data(contentsOf: url) else {
            return .success(nil) // File doesn't exist
        }
        let (_, decoder) = coder()
        do {
            let manifest = try decoder.decode(CollectionManifest.self, from: data)
            return .success(manifest)
        } catch {
            return .failure(.corrupt(url: url, underlying: error))
        }
    }

    /// Legacy compatibility: reads the manifest, returning nil for missing or corrupt.
    /// Prefer `read(from:)` for proper error handling.
    @available(*, deprecated, message: "Use read(from:) which returns Result")
    public static func readOrNil(from url: URL) -> CollectionManifest? {
        switch read(from: url) {
        case .success(let manifest): return manifest
        case .failure: return nil
        }
    }

    public func write(to url: URL) throws {
        let (encoder, _) = Self.coder()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    /// Writes a default manifest when the collection has none, so a freshly
    /// created or hand-cloned directory becomes self-describing.
    /// - Important: Never overwrites an existing manifest — even a corrupt one.
    ///   A corrupt manifest indicates data from a newer build or manual editing;
    ///   overwriting it would silently downgrade the schema version.
    @discardableResult
    public static func ensureExists(at url: URL) -> Result<CollectionManifest, CollectionManifestError> {
        switch read(from: url) {
        case .success(let existing?):
            return .success(existing)
        case .success(nil):
            // No manifest — create a fresh one
            let fresh = CollectionManifest()
            do {
                try fresh.write(to: url)
                return .success(fresh)
            } catch {
                return .failure(.writeFailed(url: url, underlying: error))
            }
        case .failure(let error):
            // Corrupt manifest — do NOT overwrite, return the error
            return .failure(error)
        }
    }
}
