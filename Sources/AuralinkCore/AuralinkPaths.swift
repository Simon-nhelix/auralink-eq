import Foundation

/// Canonical on-disk locations, shared by the app and (via the same convention)
/// the MCP server.
///
/// Two roots, with deliberately different ownership:
///
/// - **Support root** (`~/Library/Application Support/Auralink`) is *machine-local
///   state*: the working preset directory (including auditions), revision history,
///   the control token, and seeded target curves / safety rules. Auralink owns it.
/// - **Collection root** (`~/auralink-collection` by default) is the *user's own
///   headphone and preset collection*. Auralink never ships content here and never
///   writes to it without an explicit user action, so the directory can be a git
///   checkout the user owns and shares.
public enum AuralinkPaths {
    public static let bundleIdentifier = "com.auralink.eq"

    /// Environment override for the collection root, checked first so a dev or a
    /// test can point at a scratch directory.
    public static let collectionDirectoryEnvKey = "AURALINK_COLLECTION_DIR"

    /// `UserDefaults` key holding a user-chosen collection root.
    public static let collectionDirectoryDefaultsKey = "AuralinkCollectionDirectory"

    /// Collection root used when neither the environment nor `UserDefaults` names
    /// one. Deliberately outside `~/Documents`: that folder is TCC-protected, and
    /// an ad-hoc signed build loses the grant on every rebuild.
    public static let defaultCollectionDirectoryName = "auralink-collection"

    // MARK: - Machine-local state

    /// ~/Library/Application Support/Auralink
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Auralink", isDirectory: true)
    }

    /// Working presets (one JSON file per preset), including auditions. This is
    /// the directory the running engine loads from and writes to.
    public static var presetsDirectory: URL {
        supportDirectory.appendingPathComponent("presets", isDirectory: true)
    }

    /// Revision history (one subfolder per preset id).
    public static var revisionsDirectory: URL {
        supportDirectory.appendingPathComponent("revisions", isDirectory: true)
    }

    /// Target curves and safety rules, seeded from the bundle on first run so the
    /// MCP server reads the same values the app uses. No headphone data lives here.
    public static var dataDirectory: URL {
        supportDirectory.appendingPathComponent("data", isDirectory: true)
    }

    /// Shared bearer token used by the loopback ControlServer and local MCP
    /// process. The file is created with user-only permissions on first launch.
    public static var controlTokenFile: URL {
        supportDirectory.appendingPathComponent("control-token", isDirectory: false)
    }

    // MARK: - User-owned collection

    /// The user's headphone/preset collection root.
    ///
    /// Resolution order: `AURALINK_COLLECTION_DIR`, then the
    /// `AuralinkCollectionDirectory` user default, then `~/auralink-collection`.
    public static var collectionDirectory: URL {
        if let fromEnv = configuredCollectionPath(ProcessInfo.processInfo.environment[collectionDirectoryEnvKey]) {
            return fromEnv
        }
        if let fromDefaults = configuredCollectionPath(
            UserDefaults.standard.string(forKey: collectionDirectoryDefaultsKey)
        ) {
            return fromDefaults
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultCollectionDirectoryName, isDirectory: true)
    }

    /// Per-model headphone profiles (`{id}.json`).
    public static var collectionHeadphonesDirectory: URL {
        collectionDirectory.appendingPathComponent("headphones", isDirectory: true)
    }

    /// Curated presets the user chose to keep in their collection. Read-only from
    /// the app's perspective except through an explicit "add to collection" action.
    public static var collectionPresetsDirectory: URL {
        collectionDirectory.appendingPathComponent("presets", isDirectory: true)
    }

    /// Collection-level metadata (`schemaVersion`, name). See `CollectionManifest`.
    public static var collectionManifestFile: URL {
        collectionDirectory.appendingPathComponent("manifest.json", isDirectory: false)
    }

    /// Where the collection lived before it became user-owned. Kept only so the
    /// app can detect an unmigrated install and tell the user about it.
    public static var legacyLibraryDirectory: URL {
        supportDirectory.appendingPathComponent("library", isDirectory: true)
    }

    /// True when a pre-split install still has profiles in the old location and
    /// the new collection has none — the one case that needs a migration prompt.
    public static var needsCollectionMigration: Bool {
        !jsonFileNames(in: legacyLibraryDirectory.appendingPathComponent("headphones", isDirectory: true)).isEmpty
            && jsonFileNames(in: collectionHeadphonesDirectory).isEmpty
    }

    // MARK: - Setup

    /// Creates both directory trees if needed.
    ///
    /// Support directories are locked to user-only permissions because one of them
    /// holds the control token. The collection is left at the user's own umask: it
    /// may be a git checkout they manage, and silently re-chmod'ing it every launch
    /// would be overreach.
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [supportDirectory, presetsDirectory, revisionsDirectory, dataDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        for dir in [collectionDirectory, collectionHeadphonesDirectory, collectionPresetsDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Private helpers

    /// Normalizes a configured path: trims, expands `~`, rejects empty values and
    /// relative paths (a relative collection root would follow the process CWD).
    private static func configuredCollectionPath(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func jsonFileNames(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.lowercased().hasSuffix(".json") } ?? []
    }
}
