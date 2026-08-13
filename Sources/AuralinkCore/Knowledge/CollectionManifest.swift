import Foundation

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

    /// Reads the manifest at `url`, or nil when it is absent or unreadable.
    public static func read(from url: URL) -> CollectionManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let (_, decoder) = coder()
        return try? decoder.decode(CollectionManifest.self, from: data)
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
    /// created or hand-cloned directory becomes self-describing. Never overwrites
    /// an existing manifest — the user's own metadata wins.
    @discardableResult
    public static func ensureExists(at url: URL) -> CollectionManifest {
        if let existing = read(from: url) { return existing }
        let fresh = CollectionManifest()
        try? fresh.write(to: url)
        return fresh
    }
}
