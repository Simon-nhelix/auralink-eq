import Foundation

/// On-disk persistence for EQ presets.
///
/// The store keeps **one pretty-printed JSON file per preset** under
/// `directory` (named `<id>.json`) and a full revision history under
/// `revisionsDirectory/<id>/v<n>.json`. Every `save` snapshots the version
/// that was previously on disk into the revision folder *before* overwriting,
/// so edits are always reversible (`previousRevision` / `revisions`).
///
/// The same directory layout is shared with the MCP server, which reads/writes
/// the very same files — hence the stable, human-readable JSON encoding.
public final class PresetStore {
    /// Folder holding the current `<id>.json` for every preset.
    public let directory: URL
    /// Folder holding `<id>/v<n>.json` snapshots of superseded versions.
    public let revisionsDirectory: URL

    private let fileManager: FileManager

    /// Pretty, sorted, ISO-8601 — matches the MCP wire format byte-for-byte.
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, revisionsDirectory: URL) {
        self.directory = directory
        self.revisionsDirectory = revisionsDirectory
        self.fileManager = .default

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Convenience init using the canonical app locations.

    public convenience init() {
        self.init(directory: AuralinkPaths.presetsDirectory,
                  revisionsDirectory: AuralinkPaths.revisionsDirectory)
    }

    // MARK: - Loading

    /// Loads every preset, normalizing each one (exactly 20 clamped bands,
    /// clamped preamp). If the directory is empty (first run), it seeds the
    /// three factory presets and returns those instead.
    public func loadAll() throws -> [EQPreset] {
        try ensureDirectory(directory)

        let urls = try presetFileURLs()
        if urls.isEmpty {
            return try seedFactoryPresets()
        }

        var presets: [EQPreset] = []
        for url in urls {
            // Skip files that fail to decode rather than failing the whole load:
            // a single corrupt preset shouldn't sink the library.
            guard let preset = try? load(from: url) else { continue }
            presets.append(preset.normalized())
        }
        // Stable, name-then-id order for deterministic UI listing.
        return presets.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Returns the current on-disk preset with `id`, or nil if absent.
    public func get(id: String) throws -> EQPreset? {
        let url = presetURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try load(from: url).normalized()
    }

    // MARK: - Saving

    /// Persists `preset`. If a version already exists on disk it is first
    /// snapshotted into the revisions folder, then `version` is bumped and
    /// `updatedAt` is set to now. Returns the exact preset written.
    @discardableResult
    public func save(_ preset: EQPreset) throws -> EQPreset {
        try ensureDirectory(directory)

        var toWrite = preset.normalized()
        let url = presetURL(for: toWrite.id)

        if let existing = try? load(from: url) {
            // Snapshot the version currently on disk before we overwrite it.
            try snapshot(existing)
            toWrite.version = existing.version + 1
            toWrite.createdAt = existing.createdAt
        } else {
            // First time this id is written: keep its incoming version (≥1) and
            // stamp createdAt if it was never set.
            toWrite.version = max(1, toWrite.version)
            if toWrite.createdAt == Date(timeIntervalSince1970: 0) {
                toWrite.createdAt = Date()
            }
        }
        toWrite.updatedAt = Date()

        try write(toWrite, to: url)
        return toWrite
    }

    // MARK: - Deleting

    /// Removes the current preset file *and* its revision history.
    public func delete(id: String) throws {
        let url = presetURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let revDir = revisionsDirectory.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: revDir.path) {
            try fileManager.removeItem(at: revDir)
        }
    }

    // MARK: - Duplicating

    /// Creates an independent copy of `id` under a fresh id and `newName`,
    /// reset to version 1 with its own timestamps and empty revision history.
    public func duplicate(id: String, newName: String) throws -> EQPreset {
        guard var source = try get(id: id) else {
            throw PresetStoreError.notFound(id)
        }
        source.id = freshID(base: "preset")
        source.name = newName
        source.version = 1
        let now = Date()
        source.createdAt = now
        source.updatedAt = now

        let url = presetURL(for: source.id)
        try ensureDirectory(directory)
        try write(source, to: url)
        return source
    }

    // MARK: - Revisions

    /// All snapshotted prior versions of `id`, newest first. The current
    /// on-disk version is *not* included (it has not been superseded yet).
    public func revisions(of id: String) throws -> [EQPreset] {
        let revDir = revisionsDirectory.appendingPathComponent(id, isDirectory: true)
        guard fileManager.fileExists(atPath: revDir.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: revDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }

        var revs: [EQPreset] = []
        for url in urls {
            guard let preset = try? load(from: url) else { continue }
            revs.append(preset.normalized())
        }
        // Highest version first.
        return revs.sorted { $0.version > $1.version }
    }

    /// The most recent snapshot (the version that came just before the current
    /// on-disk one), or nil if no revisions exist.
    public func previousRevision(of id: String) throws -> EQPreset? {
        try revisions(of: id).first
    }

    // MARK: - Import / Export

    /// Writes `preset` as standalone pretty JSON to an arbitrary location
    /// (e.g. a file the user picked via a save panel).
    public func export(_ preset: EQPreset, to url: URL) throws {
        try write(preset.normalized(), to: url)
    }

    /// Reads a preset from an external JSON file, normalizes it, and assigns a
    /// fresh id if one with the same id already exists in the store. Returns the
    /// imported preset (not yet saved — caller decides via `save`).
    public func importPreset(from url: URL) throws -> EQPreset {
        var imported = try load(from: url).normalized()
        let existing = presetURL(for: imported.id)
        if fileManager.fileExists(atPath: existing.path) {
            imported.id = freshID(base: "preset")
        }
        return imported
    }

    // MARK: - Factory seed

    /// Writes the three shipped factory presets and returns them. Called by
    /// `loadAll` when the directory is empty.
    @discardableResult
    public func seedFactoryPresets() throws -> [EQPreset] {
        try ensureDirectory(directory)
        let presets = PresetStore.factoryPresets()
        for preset in presets {
            try write(preset, to: presetURL(for: preset.id))
        }
        return presets.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The canonical factory presets: "Flat", "Warm & Smooth", "Vocal Clarity".
    ///
    /// Each one is run through `PresetValidator` so its `safety.clippingRisk` is
    /// computed from the actual response rather than hand-guessed. The default
    /// preamp stays at unity; auto headroom is an explicit user/agent choice.
    public static func factoryPresets() -> [EQPreset] {
        let now = Date()
        let validator = PresetValidator(rules: .default)

        /// Stamps timestamps, then fills clipping risk from the validator.
        func finalize(_ preset: EQPreset) -> EQPreset {
            var p = preset.normalized()
            p.createdAt = now
            p.updatedAt = now
            let result = validator.validate(p)
            p.safety.clippingRisk = result.clippingRisk
            return p
        }

        // 1) Flat — a true bypass: all 20 bands disabled.
        let flat = finalize(EQPreset(
            id: "preset_flat",
            name: "Flat",
            goal: "Reference: no coloration.",
            preampDb: 0,
            bands: EQBand.defaultBands(),
            createdBy: .user,
            version: 1,
            tags: ["factory"]
        ))

        // 2) Warm & Smooth — gentle low-shelf lift, slightly tamed upper-mids.
        var warmBands = EQBand.defaultBands()
        warmBands[0]  = EQBand(index: 1,  type: .lowShelf, frequencyHz: 120,  gainDb: 3.0, q: 0.7, enabled: true)
        warmBands[1]  = EQBand(index: 2,  type: .bell,     frequencyHz: 250,  gainDb: 1.5, q: 0.9, enabled: true)
        warmBands[12] = EQBand(index: 13, type: .bell,     frequencyHz: 3500, gainDb: -2.0, q: 1.0, enabled: true)
        warmBands[15] = EQBand(index: 16, type: .highShelf, frequencyHz: 9000, gainDb: -1.5, q: 0.7, enabled: true)
        let warm = finalize(EQPreset(
            id: "preset_warm_smooth",
            name: "Warm & Smooth",
            goal: "Warm: lifted lows, relaxed treble for fatigue-free listening.",
            bands: warmBands,
            createdBy: .user,
            version: 1,
            tags: ["factory", "warm"]
        ))

        // 3) Vocal Clarity — presence lift, slight low-mid clean-up.
        var vocalBands = EQBand.defaultBands()
        vocalBands[3]  = EQBand(index: 4,  type: .bell, frequencyHz: 200,  gainDb: -2.0, q: 1.0, enabled: true)
        vocalBands[9]  = EQBand(index: 10, type: .bell, frequencyHz: 1100, gainDb: 1.5, q: 1.2, enabled: true)
        vocalBands[11] = EQBand(index: 12, type: .bell, frequencyHz: 2500, gainDb: 3.0, q: 1.1, enabled: true)
        vocalBands[13] = EQBand(index: 14, type: .bell, frequencyHz: 5000, gainDb: 2.0, q: 1.4, enabled: true)
        let vocal = finalize(EQPreset(
            id: "preset_vocal_clarity",
            name: "Vocal Clarity",
            goal: "Vocal: forward presence and intelligibility.",
            bands: vocalBands,
            createdBy: .user,
            version: 1,
            tags: ["factory", "vocal"]
        ))

        return [flat, warm, vocal]
    }

    // MARK: - Private helpers

    /// Snapshots a preset into `revisionsDirectory/<id>/v<version>.json`.
    private func snapshot(_ preset: EQPreset) throws {
        let revDir = revisionsDirectory.appendingPathComponent(preset.id, isDirectory: true)
        try ensureDirectory(revDir)
        let url = revDir.appendingPathComponent("v\(preset.version).json")
        try write(preset, to: url)
    }

    /// Current-version file URL for an id.
    private func presetURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// All `*.json` files in the preset directory.
    private func presetFileURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
    }

    private func load(from url: URL) throws -> EQPreset {
        let data = try Data(contentsOf: url)
        return try decoder.decode(EQPreset.self, from: data)
    }

    private func write(_ preset: EQPreset, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let data = try encoder.encode(preset)
        try data.write(to: url, options: [.atomic])
    }

    private func ensureDirectory(_ dir: URL) throws {
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// A collision-resistant fresh preset id. Uses UUID (allowed in app/core
    /// code per the build spec) so duplicates/imports never clobber an existing
    /// file.
    private func freshID(base: String) -> String {
        "\(base)_\(UUID().uuidString.prefix(8).lowercased())"
    }
}

/// Errors thrown by `PresetStore` for caller-facing conditions.
public enum PresetStoreError: Error, LocalizedError, Equatable {
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No preset found with id \"\(id)\"."
        }
    }
}
