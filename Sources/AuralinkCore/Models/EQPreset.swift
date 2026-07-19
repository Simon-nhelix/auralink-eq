import CryptoKit
import Foundation

public enum CreatedBy: String, Codable, Sendable {
    case user
    case ai
}

public enum ClippingRisk: String, Codable, Sendable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }
}

/// Safety metadata stored alongside a preset.
public struct PresetSafety: Codable, Equatable, Sendable {
    public var autoGainEnabled: Bool
    public var clippingRisk: ClippingRisk

    public init(autoGainEnabled: Bool = false, clippingRisk: ClippingRisk = .low) {
        self.autoGainEnabled = autoGainEnabled
        self.clippingRisk = clippingRisk
    }
}

public enum CorrectionRole: String, Codable, Sendable {
    case generic
    case baseline
    case preference
    case combined
}

public enum CorrectionSourceConfidence: String, Codable, Sendable {
    case measured
    case manufacturer
    case community
    case estimated
    case unknown
}

/// One point from a persisted measured correction curve. Gain excludes the
/// preset's global preamp so headroom is applied exactly once by EQProcessor.
public struct MeasuredCorrectionPoint: Codable, Equatable, Sendable {
    public var frequencyHz: Double
    public var gainDb: Double

    public init(frequencyHz: Double, gainDb: Double) {
        self.frequencyHz = frequencyHz
        self.gainDb = gainDb
    }
}

/// Versioned, portable magnitude-only correction data used by Measured FIR.
/// Derived taps are intentionally not serialized: they are rebuilt and cached
/// for the exact live sample rate.
public struct MeasuredCorrectionPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let pointCountRange = 16...512
    public static let frequencyRange = 10.0...24_000.0
    public static let gainRange = -24.0...24.0

    public var schemaVersion: Int
    public var measurementId: String
    public var sourceFormat: String
    public var source: String
    public var rig: String?
    public var provenanceURL: String
    /// Preamp removed from the source GraphicEQ values. Informational only;
    /// `EQPreset.preampDb` remains the sole runtime preamp.
    public var sourcePreampDb: Double
    public var contentHash: String
    public var channel: String
    public var phaseData: String
    public var usableLowHz: Double
    public var usableHighHz: Double
    public var points: [MeasuredCorrectionPoint]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        measurementId: String,
        sourceFormat: String = "autoeq_graphic_eq",
        source: String,
        rig: String? = nil,
        provenanceURL: String,
        sourcePreampDb: Double,
        contentHash: String,
        channel: String = "stereo",
        phaseData: String = "magnitude_only",
        usableLowHz: Double = 40,
        usableHighHz: Double = 10_000,
        points: [MeasuredCorrectionPoint]
    ) {
        self.schemaVersion = schemaVersion
        self.measurementId = measurementId
        self.sourceFormat = sourceFormat
        self.source = source
        self.rig = rig
        self.provenanceURL = provenanceURL
        self.sourcePreampDb = sourcePreampDb
        self.contentHash = contentHash
        self.channel = channel
        self.phaseData = phaseData
        self.usableLowHz = usableLowHz
        self.usableHighHz = usableHighHz
        self.points = points
    }

    /// True only for the measured-magnitude contract the production FIR path
    /// understands. Future schema values remain decodable but fail closed.
    public var isFIREligible: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              sourceFormat == "autoeq_graphic_eq",
              channel == "stereo",
              phaseData == "magnitude_only",
              !measurementId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !provenanceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              contentHash.count == 64,
              contentHash == computedContentHash,
              sourcePreampDb.isFinite,
              Self.pointCountRange.contains(points.count),
              usableLowHz.isFinite,
              usableHighHz.isFinite,
              usableLowHz >= Self.frequencyRange.lowerBound,
              usableHighHz <= Self.frequencyRange.upperBound,
              usableHighHz > usableLowHz else { return false }

        var previous = -Double.infinity
        for point in points {
            guard point.frequencyHz.isFinite,
                  point.gainDb.isFinite,
                  Self.frequencyRange.contains(point.frequencyHz),
                  Self.gainRange.contains(point.gainDb),
                  point.frequencyHz > previous else { return false }
            previous = point.frequencyHz
        }
        guard let first = points.first, let last = points.last else { return false }
        return first.frequencyHz <= usableLowHz && last.frequencyHz >= usableHighHz
    }

    /// SHA-256 identity used by AutoEq and every cache boundary. The six-decimal
    /// representation is shared with the TypeScript parser.
    public var computedContentHash: String {
        Self.contentHash(schemaVersion: schemaVersion, points: points)
    }

    public static func contentHash(
        schemaVersion: Int = currentSchemaVersion,
        points: [MeasuredCorrectionPoint]
    ) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let canonical = points.map {
            String(format: "%.6f:%.6f", locale: locale, $0.frequencyHz, $0.gainDb)
        }.joined(separator: "|")
        let digest = SHA256.hash(data: Data("\(schemaVersion)|\(canonical)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Metadata normalization deliberately never sorts, clamps, deduplicates,
    /// truncates, or re-hashes measured points. Malformed/noncanonical data must
    /// remain ineligible rather than being silently changed into a new curve.
    public func normalized() -> MeasuredCorrectionPayload {
        var copy = self
        copy.measurementId = measurementId.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sourceFormat = sourceFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.rig = rig?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.provenanceURL = provenanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.contentHash = contentHash.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        copy.channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.phaseData = phaseData.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    /// Log-frequency interpolation of the persisted correction magnitude.
    /// Callers apply correction strength and high-frequency regularization.
    public func magnitudeDb(atHz frequencyHz: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        let frequency = max(frequencyHz, 1e-6)
        if frequency <= points[0].frequencyHz { return points[0].gainDb }
        if frequency >= points[points.count - 1].frequencyHz { return points[points.count - 1].gainDb }

        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].frequencyHz <= frequency {
                low = middle
            } else {
                high = middle
            }
        }
        let lo = points[low]
        let hi = points[high]
        let denominator = log(hi.frequencyHz) - log(lo.frequencyHz)
        guard abs(denominator) > 1e-12 else { return hi.gainDb }
        let t = (log(frequency) - log(lo.frequencyHz)) / denominator
        return lo.gainDb + (hi.gainDb - lo.gainDb) * t
    }
}

/// Optional workflow metadata that separates measured/model correction from
/// later subjective preference moves.
public struct CorrectionMetadata: Codable, Equatable, Sendable {
    public var role: CorrectionRole
    public var baselinePresetId: String?
    public var source: String?
    public var sourceConfidence: CorrectionSourceConfidence
    /// 0...1 scale for how strongly the measured/model correction is applied.
    public var correctionStrength: Double
    public var targetCurveId: String?
    /// 0...1 scale for target-curve blending/strength.
    public var targetBlend: Double
    /// Band indexes that are subjective preference moves rather than baseline correction.
    public var preferenceBandIndexes: [Int]
    /// Dense measured baseline used only by Auralink's software FIR renderer.
    /// Hardware PEQ targets continue to use the parametric `bands` fallback.
    public var measuredCorrection: MeasuredCorrectionPayload?

    public init(
        role: CorrectionRole = .generic,
        baselinePresetId: String? = nil,
        source: String? = nil,
        sourceConfidence: CorrectionSourceConfidence = .unknown,
        correctionStrength: Double = 1,
        targetCurveId: String? = nil,
        targetBlend: Double = 1,
        preferenceBandIndexes: [Int] = [],
        measuredCorrection: MeasuredCorrectionPayload? = nil
    ) {
        self.role = role
        self.baselinePresetId = baselinePresetId
        self.source = source
        self.sourceConfidence = sourceConfidence
        self.correctionStrength = min(max(correctionStrength, 0), 1)
        self.targetCurveId = targetCurveId
        self.targetBlend = min(max(targetBlend, 0), 1)
        self.preferenceBandIndexes = preferenceBandIndexes
            .filter { (1...EQBand.bandCount).contains($0) }
            .uniquedSorted()
        self.measuredCorrection = measuredCorrection?.normalized()
    }
}

/// A complete, saveable EQ preset.
///
/// This is the document model of the app: every preset the user or the AI
/// creates is one of these, serialized to JSON on disk and over MCP. The JSON
/// shape matches the example in the product plan (§7.3).
public struct EQPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Target headphone model, e.g. "Sennheiser HD600". Optional for generic presets.
    public var headphone: String?
    /// Free-text tuning intent, e.g. "Rock: punchy kick, clear guitars, preserved vocals".
    public var goal: String?
    /// Global pre-amplification in dB (usually negative to leave clipping headroom).
    public var preampDb: Double
    public var bands: [EQBand]
    public var safety: PresetSafety
    public var createdBy: CreatedBy
    /// Monotonic version number, bumped on every saved edit (see PresetStore).
    public var version: Int
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    /// Optional correction workflow metadata for baseline/preference separation.
    public var correction: CorrectionMetadata?

    public init(
        id: String,
        name: String,
        headphone: String? = nil,
        goal: String? = nil,
        preampDb: Double = 0,
        bands: [EQBand],
        safety: PresetSafety = PresetSafety(),
        createdBy: CreatedBy = .user,
        version: Int = 1,
        tags: [String] = [],
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        correction: CorrectionMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.headphone = headphone
        self.goal = goal
        self.preampDb = preampDb
        self.bands = bands
        self.safety = safety
        self.createdBy = createdBy
        self.version = version
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.correction = correction
    }

    // Tolerant decoding: older/AI-authored JSON may omit metadata fields.
    enum CodingKeys: String, CodingKey {
        case id, name, headphone, goal, preampDb, bands, safety, createdBy, version, tags, createdAt, updatedAt, correction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        headphone = try c.decodeIfPresent(String.self, forKey: .headphone)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        preampDb = try c.decodeIfPresent(Double.self, forKey: .preampDb) ?? 0
        bands = try c.decode([EQBand].self, forKey: .bands)
        safety = try c.decodeIfPresent(PresetSafety.self, forKey: .safety) ?? PresetSafety()
        createdBy = try c.decodeIfPresent(CreatedBy.self, forKey: .createdBy) ?? .user
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        correction = try c.decodeIfPresent(CorrectionMetadata.self, forKey: .correction)
    }
}

public extension EQPreset {
    static let preampRange: ClosedRange<Double> = -24...0

    /// A flat default preset (all bands disabled).
    static func flat(id: String = "preset_flat", name: String = "Flat") -> EQPreset {
        EQPreset(id: id, name: name, preampDb: 0, bands: EQBand.defaultBands(), createdBy: .user)
    }

    /// Only the bands that actually affect the sound.
    var activeBands: [EQBand] {
        bands.filter { $0.enabled }
    }

    /// Normalizes the band array so it always has exactly 20 indexed slots,
    /// filling gaps with empty bands and clamping every parameter.
    func normalized() -> EQPreset {
        var byIndex: [Int: EQBand] = [:]
        for b in bands { byIndex[b.index] = b.clamped() }
        let full = (1...EQBand.bandCount).map { byIndex[$0] ?? EQBand.emptyBand(index: $0) }
        var copy = self
        copy.bands = full
        copy.preampDb = Swift.min(Swift.max(preampDb, EQPreset.preampRange.lowerBound), EQPreset.preampRange.upperBound)
        if var correction = copy.correction {
            correction.correctionStrength = min(max(correction.correctionStrength, 0), 1)
            correction.targetBlend = min(max(correction.targetBlend, 0), 1)
            correction.preferenceBandIndexes = correction.preferenceBandIndexes
                .filter { (1...EQBand.bandCount).contains($0) }
                .uniquedSorted()
            correction.measuredCorrection = correction.measuredCorrection?.normalized()
            copy.correction = correction
        }
        return copy
    }
}

private extension Array where Element == Int {
    func uniquedSorted() -> [Int] {
        Array(Set(self)).sorted()
    }
}
