import Foundation

/// Canonical on-disk locations, shared by the app and (via the same convention)
/// the MCP server. Everything lives under Application Support so presets and
/// knowledge data survive app updates and are reachable by an external process.
public enum AuralinkPaths {
    public static let bundleIdentifier = "com.auralink.eq"

    /// ~/Library/Application Support/Auralink
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Auralink", isDirectory: true)
    }

    /// User presets (one JSON file per preset).
    public static var presetsDirectory: URL {
        supportDirectory.appendingPathComponent("presets", isDirectory: true)
    }

    /// Revision history (one subfolder per preset id).
    public static var revisionsDirectory: URL {
        supportDirectory.appendingPathComponent("revisions", isDirectory: true)
    }

    /// Knowledge data (headphone profiles / target curves / safety rules),
    /// seeded from the bundle on first run so the MCP server can read it.
    public static var dataDirectory: URL {
        supportDirectory.appendingPathComponent("data", isDirectory: true)
    }

    /// Shared bearer token used by the loopback ControlServer and local MCP
    /// process. The file is created with user-only permissions on first launch.
    public static var controlTokenFile: URL {
        supportDirectory.appendingPathComponent("control-token", isDirectory: false)
    }

    /// Creates the directory tree if needed.
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [supportDirectory, presetsDirectory, revisionsDirectory, dataDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}
