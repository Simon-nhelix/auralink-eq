import Foundation

/// The read-only knowledge layer behind every tuning decision.
///
/// `KnowledgeBase` loads the three shipped JSON files — headphone profiles,
/// target curves, and the safety rules — and decodes them into the canonical
/// `Models` types. Two sources are tried, in order:
///
/// 1. A caller-supplied `dataDirectory` (e.g. `AuralinkPaths.dataDirectory`,
///    which the app seeds on first run and which the MCP server points at). This
///    lets the data be edited on disk without rebuilding the app.
/// 2. The canonical app copy under `Contents/Resources` for installed builds,
///    then `Bundle.module/data` for SwiftPM development and tests.
///
/// If a file is missing or fails to decode at *both* locations, a safe empty
/// (or default) value is used instead of crashing — the app degrades to "no
/// profiles" rather than failing to launch.
public final class KnowledgeBase {

    // MARK: Stored knowledge

    private let profiles: [HeadphoneProfile]
    private let curves: [TargetCurve]
    private let rules: SafetyRules

    // MARK: Init

    /// Loads the knowledge base, preferring `dataDirectory` and falling back to
    /// the resource bundle. Pass `nil` to load from the bundle only.
    public init(dataDirectory: URL?) {
        let decoder = JSONDecoder()

        self.profiles = KnowledgeBase.load(
            [HeadphoneProfile].self,
            file: "headphone-profiles",
            dataDirectory: dataDirectory,
            decoder: decoder
        ) ?? []

        self.curves = KnowledgeBase.load(
            [TargetCurve].self,
            file: "target-curves",
            dataDirectory: dataDirectory,
            decoder: decoder
        ) ?? []

        self.rules = KnowledgeBase.load(
            SafetyRules.self,
            file: "safety-rules",
            dataDirectory: dataDirectory,
            decoder: decoder
        ) ?? .default
    }

    // MARK: Accessors

    public var headphoneProfiles: [HeadphoneProfile] { profiles }
    public var targetCurves: [TargetCurve] { curves }
    public var safetyRules: SafetyRules { rules }

    /// Exact profile lookup by slug id (e.g. "sennheiser-hd600").
    public func profile(id: String) -> HeadphoneProfile? {
        profiles.first { $0.id == id }
    }

    /// Fuzzy profile lookup used when the request carries a free-text headphone
    /// name. Matching is case-insensitive and whitespace-insensitive, trying, in
    /// priority order: exact id, exact display name, then substring matches
    /// against slug / brand / model / "brand model". A normalized, alphanumeric
    /// form ("HD 600" → "hd600") is also compared so spacing and punctuation
    /// differences still match.
    public func profileMatching(_ name: String) -> HeadphoneProfile? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let lower = query.lowercased()
        let squashed = KnowledgeBase.alphanumeric(lower)

        // 1. Exact id or display name.
        if let exact = profiles.first(where: {
            $0.id.lowercased() == lower || $0.displayName.lowercased() == lower
        }) {
            return exact
        }

        // 2. Substring / squashed-substring match.
        for p in profiles {
            let haystacks = [
                p.id.lowercased(),
                p.brand.lowercased(),
                p.model.lowercased(),
                p.displayName.lowercased()
            ]
            for h in haystacks {
                if h.contains(lower) || lower.contains(h) {
                    return p
                }
            }
            let squashedHaystacks = haystacks.map(KnowledgeBase.alphanumeric)
            for h in squashedHaystacks where !h.isEmpty {
                if h.contains(squashed) || squashed.contains(h) {
                    return p
                }
            }
        }
        return nil
    }

    /// Exact target-curve lookup by slug id (e.g. "rock").
    public func targetCurve(id: String) -> TargetCurve? {
        curves.first { $0.id == id }
    }

    // MARK: Seeding (for the MCP server / first run)

    /// Copies the bundled JSON files into `dir` for any file that is missing, so
    /// an external process (the MCP server) can read the same knowledge data
    /// from a stable on-disk location. Existing files are never overwritten, so
    /// user edits survive. Failures are ignored — this is best-effort seeding.
    public func seedDataDirectory(_ dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for file in ["headphone-profiles", "target-curves", "safety-rules"] {
            let destination = dir.appendingPathComponent("\(file).json")
            guard !fm.fileExists(atPath: destination.path) else { continue }
            guard let source = KnowledgeBase.bundledURL(for: file) else { continue }
            try? fm.copyItem(at: source, to: destination)
        }
    }

    // MARK: - Loading helpers

    /// Attempts to decode `T` from `<dataDirectory>/<file>.json`, then from the
    /// bundled `<file>.json`. Returns `nil` if neither source decodes.
    private static func load<T: Decodable>(
        _ type: T.Type,
        file: String,
        dataDirectory: URL?,
        decoder: JSONDecoder
    ) -> T? {
        // 1. Caller-supplied directory.
        if let dir = dataDirectory {
            let url = dir.appendingPathComponent("\(file).json")
            if let value = decode(type, at: url, decoder: decoder) {
                return value
            }
        }
        // 2. Bundled fallback.
        if let url = bundledURL(for: file) {
            return decode(type, at: url, decoder: decoder)
        }
        return nil
    }

    /// Decodes `T` from a file URL, returning `nil` if the file is absent or the
    /// contents do not match the schema (rather than throwing).
    private static func decode<T: Decodable>(_ type: T.Type, at url: URL, decoder: JSONDecoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// URL of a bundled JSON resource. The data folder is copied verbatim into
    /// the resource bundle as `data/`, so the file lives in that subdirectory.
    private static func bundledURL(for file: String) -> URL? {
        if let resources = Bundle.main.resourceURL {
            let packagedURL = resources
                .appendingPathComponent("Auralink_AuralinkCore.bundle", isDirectory: true)
                .appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent("\(file).json", isDirectory: false)
            if FileManager.default.fileExists(atPath: packagedURL.path) {
                return packagedURL
            }
        }
        return Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "data")
    }

    /// Lowercased alphanumeric squash used for spacing-insensitive matching.
    private static func alphanumeric(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
