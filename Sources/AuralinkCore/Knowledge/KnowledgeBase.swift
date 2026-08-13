import CryptoKit
import Foundation

/// The read-only knowledge layer behind every tuning decision.
///
/// `KnowledgeBase` loads headphone profiles, target curves, and safety rules.
///
/// Headphone profiles come from exactly one place: per-file
/// `collectionHeadphonesDirectory/{id}.json` in the user's own collection.
/// Auralink ships no headphone data — a shipped database would push one person's
/// hearing and taste onto everyone. A user with an empty collection names their
/// headphone and the MCP layer fetches a public AutoEq measurement on demand.
///
/// Target curves and safety rules *are* app machinery (`TuningEngine` refers to
/// curve ids directly), so they keep the aggregate JSON path: `dataDirectory`
/// then the bundle.
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
    ///   - dataDirectory: aggregate JSON directory for curves and rules (typically
    ///     `AuralinkPaths.dataDirectory`)
    ///   - collectionHeadphonesDirectory: the user's per-file profile directory
    ///     (typically `AuralinkPaths.collectionHeadphonesDirectory`). Pass `nil`
    ///     for no headphone profiles at all.
    public init(dataDirectory: URL?, collectionHeadphonesDirectory: URL? = nil) {
        let decoder = JSONDecoder()

        self.profiles = KnowledgeBase.loadProfiles(
            collectionHeadphonesDirectory: collectionHeadphonesDirectory,
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

    /// Outcome of `seedDataDirectory`: what changed and what was left alone.
    public struct SeedResult: Equatable, Sendable {
        /// Files replaced with the bundled version (fresh seed or upgrade).
        public var refreshed: [String] = []
        /// Files whose on-disk content differs from what the app last seeded
        /// (user-modified) — kept as-is, caller may want to surface this.
        public var keptUserModified: [String] = []
    }

    /// Sidecar recording the SHA-256 of what the app last seeded, so upgrades
    /// can tell "stale app-owned copy" apart from "user-modified copy".
    private static let seedHashesFileName = ".seed-hashes.json"

    /// The app-owned knowledge files that are seeded from the bundle.
    private static let seededFiles = ["target-curves", "safety-rules"]

    /// Copies the bundled target curves and safety rules into `dir` and — unlike
    /// the original seed-once behavior — refreshes them on app upgrades.
    ///
    /// These files are app machinery (`TuningEngine` refers to curve ids and
    /// rule values directly), so an upgrade that ships new curves or rules must
    /// reach existing installs too; otherwise a migrated profile can reference
    /// a curve the stale seeded copy does not define.
    ///
    /// Policy per file:
    /// - missing → copy the bundled file, record its hash
    /// - on-disk content matches the recorded seed hash and the bundle changed
    ///   → atomically replace (clean upgrade), record the new hash
    /// - no recorded hash (pre-tracking install) → replace with the bundle
    ///   (these files are app-owned; user customizations were never a contract)
    /// - on-disk content differs from the recorded seed → user-modified: keep it
    ///   and report via `SeedResult.keptUserModified`
    ///
    /// Headphone profiles are deliberately absent: nothing seeds the user's
    /// collection, because Auralink has no headphone data to give it.
    @discardableResult
    public func seedDataDirectory(_ dir: URL) -> SeedResult {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var result = SeedResult()
        var recorded = Self.loadSeedHashes(from: dir)

        for file in Self.seededFiles {
            let destination = dir.appendingPathComponent("\(file).json")
            guard let source = KnowledgeBase.bundledURL(for: file),
                  let bundleData = try? Data(contentsOf: source) else { continue }
            let bundleHash = Self.sha256Hex(bundleData)
            let diskData = try? Data(contentsOf: destination)
            let diskHash = diskData.map(Self.sha256Hex)
            let recordedHash = recorded[file]

            if diskData == nil {
                // Fresh seed.
                try? bundleData.write(to: destination, options: [.atomic])
                recorded[file] = bundleHash
                result.refreshed.append(file)
                continue
            }

            if recordedHash == nil {
                // Pre-tracking install: treat as app-owned and converge on the bundle.
                if diskHash != bundleHash {
                    try? bundleData.write(to: destination, options: [.atomic])
                    result.refreshed.append(file)
                }
                recorded[file] = bundleHash
                continue
            }

            if diskHash == recordedHash {
                // Untouched since seeding: safe to upgrade.
                if diskHash != bundleHash {
                    try? bundleData.write(to: destination, options: [.atomic])
                    recorded[file] = bundleHash
                    result.refreshed.append(file)
                }
            } else {
                // User (or another process) modified the file after seeding: keep it.
                result.keptUserModified.append(file)
            }
        }

        Self.saveSeedHashes(recorded, to: dir)
        return result
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadSeedHashes(from dir: URL) -> [String: String] {
        let url = dir.appendingPathComponent(seedHashesFileName)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func saveSeedHashes(_ hashes: [String: String], to dir: URL) {
        let url = dir.appendingPathComponent(seedHashesFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hashes) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Loading helpers

    private static func loadProfiles(
        collectionHeadphonesDirectory: URL?,
        decoder: JSONDecoder
    ) -> [HeadphoneProfile] {
        guard let dir = collectionHeadphonesDirectory else { return [] }

        var byId: [String: HeadphoneProfile] = [:]
        for p in loadProfilesFromLibraryDirectory(dir, decoder: decoder) where !p.id.isEmpty {
            byId[p.id] = p
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
