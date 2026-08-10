import Foundation

/// The read-only knowledge layer behind every tuning decision.
///
/// `KnowledgeBase` loads headphone profiles, target curves, and safety rules.
/// Headphone profiles are merged from, in ascending override order:
///
/// 1. Bundled `data/headphone-profiles.json` (factory seed)
/// 2. Caller `dataDirectory/headphone-profiles.json` (Application Support aggregate)
/// 3. Per-file `libraryHeadphonesDirectory/{id}.json` (shared library — preferred)
///
/// Target curves and safety rules still use the aggregate JSON path
/// (`dataDirectory` then bundle).
///
/// If a source is missing or fails to decode, it is skipped rather than crashing —
/// the app degrades to "no profiles" rather than failing to launch.
public final class KnowledgeBase {

    // MARK: Stored knowledge

    private let profiles: [HeadphoneProfile]
    private let curves: [TargetCurve]
    private let rules: SafetyRules

    // MARK: Init

    /// Loads the knowledge base.
    /// - Parameters:
    ///   - dataDirectory: aggregate JSON directory (typically `AuralinkPaths.dataDirectory`)
    ///   - libraryHeadphonesDirectory: per-file profile directory (typically
    ///     `AuralinkPaths.libraryHeadphonesDirectory`). Pass `nil` to skip.
    public init(dataDirectory: URL?, libraryHeadphonesDirectory: URL? = nil) {
        let decoder = JSONDecoder()

        self.profiles = KnowledgeBase.loadProfiles(
            dataDirectory: dataDirectory,
            libraryHeadphonesDirectory: libraryHeadphonesDirectory ?? dataDirectory.map {
                $0.deletingLastPathComponent()
                    .appendingPathComponent("library", isDirectory: true)
                    .appendingPathComponent("headphones", isDirectory: true)
            },
            decoder: decoder
        )

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

        if let exact = profiles.first(where: {
            $0.id.lowercased() == lower || $0.displayName.lowercased() == lower
        }) {
            return exact
        }

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
    /// from a stable on-disk location. Existing files are never overwritten.
    /// Also expands the bundled headphone aggregate into per-file library
    /// entries when the library directory is empty.
    public func seedDataDirectory(_ dir: URL, libraryHeadphonesDirectory: URL? = nil) {
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

        // Seed per-file library from the aggregate when the library is empty.
        let libDir = libraryHeadphonesDirectory
            ?? dir.deletingLastPathComponent()
                .appendingPathComponent("library", isDirectory: true)
                .appendingPathComponent("headphones", isDirectory: true)
        seedLibraryHeadphonesIfEmpty(libDir, aggregateDirectory: dir)
    }

    /// Writes one profile per file under `libraryHeadphonesDirectory` when that
    /// directory has no `*.json` files yet. Uses the already-merged profile list
    /// when available, otherwise decodes the aggregate seed.
    public func seedLibraryHeadphonesIfEmpty(_ libraryDir: URL, aggregateDirectory: URL?) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: libraryDir.path) {
            try? fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        }
        let existing = (try? fm.contentsOfDirectory(atPath: libraryDir.path))?
            .filter { $0.lowercased().hasSuffix(".json") } ?? []
        guard existing.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var sourceProfiles = profiles
        if sourceProfiles.isEmpty {
            let decoder = JSONDecoder()
            sourceProfiles = KnowledgeBase.load(
                [HeadphoneProfile].self,
                file: "headphone-profiles",
                dataDirectory: aggregateDirectory,
                decoder: decoder
            ) ?? []
        }
        for profile in sourceProfiles {
            let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let url = libraryDir.appendingPathComponent("\(id).json")
            guard let data = try? encoder.encode(profile) else { continue }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Loading helpers

    private static func loadProfiles(
        dataDirectory: URL?,
        libraryHeadphonesDirectory: URL?,
        decoder: JSONDecoder
    ) -> [HeadphoneProfile] {
        var byId: [String: HeadphoneProfile] = [:]

        // 1. Bundled aggregate
        if let url = bundledURL(for: "headphone-profiles"),
           let bundled = decode([HeadphoneProfile].self, at: url, decoder: decoder) {
            for p in bundled where !p.id.isEmpty {
                byId[p.id] = p
            }
        }

        // 2. Application Support aggregate (may include user-only entries)
        if let dir = dataDirectory {
            let url = dir.appendingPathComponent("headphone-profiles.json")
            if let disk = decode([HeadphoneProfile].self, at: url, decoder: decoder) {
                for p in disk where !p.id.isEmpty {
                    byId[p.id] = p
                }
            }
        }

        // 3. Per-file library (preferred shared source of truth)
        if let libDir = libraryHeadphonesDirectory {
            for p in loadProfilesFromLibraryDirectory(libDir, decoder: decoder) where !p.id.isEmpty {
                byId[p.id] = p
            }
        }

        return byId.values.sorted {
            "\($0.brand) \($0.model)".localizedCaseInsensitiveCompare("\($1.brand) \($1.model)") == .orderedAscending
        }
    }

    private static func loadProfilesFromLibraryDirectory(
        _ directory: URL,
        decoder: JSONDecoder
    ) -> [HeadphoneProfile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var out: [HeadphoneProfile] = []
        for entry in entries where entry.lowercased().hasSuffix(".json") {
            let url = directory.appendingPathComponent(entry)
            if let profile = decode(HeadphoneProfile.self, at: url, decoder: decoder) {
                out.append(profile)
            }
        }
        return out
    }

    /// Attempts to decode `T` from `<dataDirectory>/<file>.json`, then from the
    /// bundled `<file>.json`. Returns `nil` if neither source decodes.
    private static func load<T: Decodable>(
        _ type: T.Type,
        file: String,
        dataDirectory: URL?,
        decoder: JSONDecoder
    ) -> T? {
        if let dir = dataDirectory {
            let url = dir.appendingPathComponent("\(file).json")
            if let value = decode(type, at: url, decoder: decoder) {
                return value
            }
        }
        if let url = bundledURL(for: file) {
            return decode(type, at: url, decoder: decoder)
        }
        return nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL, decoder: JSONDecoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

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

    private static func alphanumeric(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
