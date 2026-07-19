import Foundation

/// The deterministic, heuristic "AI" tuning engine.
///
/// `TuningEngine` is the single piece of logic that turns a natural-language
/// request (a `HeadphoneProfile` + a `TargetCurve`/goal text + a free-text
/// preference + safety constraints) into a concrete, validated `EQPreset` with a
/// plain-English account of what it did and why. It backs both the in-app AI
/// Tuning Panel and the MCP `create_eq_preset` flow.
///
/// **Determinism is a hard contract.** Given the same `KnowledgeBase`,
/// `PresetValidator`, request, and base preset, `makeTuning` must always produce
/// byte-identical output. There is no randomness, no clock, and no UUID anywhere
/// in the synthesis path — ids and timestamps are derived from the inputs so the
/// same request twice yields the same preset (the MCP layer / `PresetStore`
/// assigns the real persisted id/dates on save).
public final class TuningEngine {

    private let knowledge: KnowledgeBase
    private let validator: PresetValidator

    public init(knowledge: KnowledgeBase, validator: PresetValidator) {
        self.knowledge = knowledge
        self.validator = validator
    }

    // MARK: - Primary entry point

    /// Synthesizes a tuning from a request, explaining it relative to `basePreset`
    /// (the preset the change is layered on top of, used to compute the diff in
    /// `changes`). When `basePreset` is `nil`, the diff is taken against a flat
    /// preset.
    public func makeTuning(request: AITuningRequest, basePreset: EQPreset?) -> TuningResult {
        let base = (basePreset ?? .flat()).normalized()
        let profile = resolveProfile(request)
        let curve = resolveCurve(request, profile: profile)
        let goalLabel = goalLabel(request, curve: curve)
        let sourceConfidence = effectiveSourceConfidence(base: base, profile: profile)
        let appliedCorrectionStrength = conservativeCorrectionStrength(
            request.correctionStrength,
            confidence: sourceConfidence
        )

        // 1. Gather the candidate moves: start from the target-curve hints (or
        //    keyword-derived hints when no curve resolved), then apply
        //    headphone-specific corrections and preference nudges. Each move is a
        //    (frequency, type, gain, q, rationale) tuple; overlapping moves on
        //    the same frequency/type are merged so we stay within 20 bands.
        var moves = baseMoves(request: request, curve: curve)
        moves = applyHeadphoneCorrections(
            moves,
            profile: profile,
            request: request,
            correctionStrength: appliedCorrectionStrength
        )
        moves = applyPreferenceNudges(moves, request: request)

        // 2. Resolve safety ceilings: the request may tighten (never loosen) the
        //    shipped maxBoostDb.
        let rules = knowledge.safetyRules
        let maxBoost = effectiveMaxBoost(request: request, rules: rules)

        // 3. Materialize moves into clamped bands, honoring avoidHarshTreble and
        //    the boost ceiling.
        let generatedBands = materialize(moves, maxBoost: maxBoost, avoidHarshTreble: request.avoidHarshTreble)
        let bands = compose(basePreset: basePreset, base: base, generatedBands: generatedBands)

        // 4. Assemble the preset. The id/name are derived deterministically; the
        //    persistence layer reassigns the canonical id on save.
        let intentText = intentSummary(curve: curve, profile: profile, request: request)
        let name = presetName(profile: profile, goal: goalLabel)
        var preset = EQPreset(
            id: derivedId(profile: profile, goal: goalLabel),
            name: name,
            headphone: profile?.displayName ?? basePreset?.headphone,
            goal: intentText,
            preampDb: basePreset == nil ? 0 : base.preampDb,
            bands: bands,
            safety: PresetSafety(autoGainEnabled: false, clippingRisk: .low),
            createdBy: .ai,
            tags: tags(curve: curve, profile: profile)
        ).normalized()

        // 5. Validate with the baseline preamp preserved (or unity when there is
        //    no baseline). Auralink's live-audition workflow preserves level and
        //    dynamics unless the user explicitly asks for auto headroom.
        let validation = validator.validate(preset)
        preset.safety.clippingRisk = validation.clippingRisk

        // 6. Build the human-readable intent bullets and the per-band change list.
        let intent = intentBullets(curve: curve, profile: profile, request: request)
        let changes = diff(from: base, to: preset, curve: curve)
        preset.correction = correctionMetadata(
            request: request,
            profile: profile,
            curve: curve,
            base: base,
            sourceConfidence: sourceConfidence,
            appliedCorrectionStrength: appliedCorrectionStrength,
            changedBandIndexes: changes.map(\.bandIndex)
        )
        let basis = basisString(profile: profile, curve: curve)

        return TuningResult(
            preset: preset,
            intent: intent,
            changes: changes,
            validation: validation,
            basis: basis
        )
    }

    // MARK: - Quick actions

    /// "Warmer": layers a gentle low / low-mid shelf onto an existing preset to
    /// add body and warmth, then revalidates. Deterministic.
    public func warmer(_ preset: EQPreset) -> TuningResult {
        let base = preset.normalized()
        var moves = movesFromPreset(base)
        // Gentle, additive warmth: a low shelf plus a small lower-mid lift.
        moves = mergeIn(moves, Move(type: .lowShelf, frequencyHz: 120, gainDb: 2.5, q: 0.7,
                                    rationale: "Add low-end warmth and body."))
        moves = mergeIn(moves, Move(type: .bell, frequencyHz: 300, gainDb: 1.0, q: 1.0,
                                    rationale: "Fill in the lower mids for a fuller tone."))

        let rules = knowledge.safetyRules
        let bands = materialize(moves, maxBoost: rules.maxBoostDb, avoidHarshTreble: false)

        var result = base
        result.bands = bands
        result.createdBy = .ai
        result.name = appendSuffix(base.name, suffix: "Warmer")
        result.goal = "Warmer: added low-shelf warmth and lower-mid body."
        result.safety.autoGainEnabled = false
        result = result.normalized()

        let validation = validator.validate(result)
        result.safety.clippingRisk = validation.clippingRisk

        let changes = diff(from: base, to: result, curve: nil)
        result.correction = CorrectionMetadata(
            role: .preference,
            baselinePresetId: base.id,
            source: "Quick action: warmer",
            sourceConfidence: .unknown,
            correctionStrength: base.correction?.correctionStrength ?? 1,
            targetCurveId: base.correction?.targetCurveId,
            targetBlend: base.correction?.targetBlend ?? 1,
            preferenceBandIndexes: changes.map(\.bandIndex)
        )
        return TuningResult(
            preset: result,
            intent: ["Add low-end warmth and body", "Fill in the lower mids gently"],
            changes: changes,
            validation: validation,
            basis: "Quick action: warmer"
        )
    }

    /// "Reduce harshness": cuts `amountDb` (a positive magnitude) in the 5–9 kHz
    /// region — where most fatiguing treble peaks live — preferring the
    /// headphone's known harsh regions when the preset names one. Deterministic.
    public func reduceHarshness(in preset: EQPreset, amountDb: Double) -> TuningResult {
        let base = preset.normalized()
        // Treat the input as a magnitude of cut; clamp to a sane range.
        let cut = -abs(min(max(amountDb, 0), EQBand.gainRange.upperBound))

        var moves = movesFromPreset(base)
        // Pick the cut centers from the headphone's harsh regions if available,
        // otherwise default across the canonical 5–9 kHz fatigue band.
        let centers = harshCenters(for: base.headphone)
        for f in centers {
            moves = mergeIn(moves, Move(type: .bell, frequencyHz: f, gainDb: cut, q: 2.0,
                                        rationale: "Cut fatiguing energy near \(Int(f.rounded())) Hz."))
        }

        let rules = knowledge.safetyRules
        let bands = materialize(moves, maxBoost: rules.maxBoostDb, avoidHarshTreble: true)

        var result = base
        result.bands = bands
        result.createdBy = .ai
        result.name = appendSuffix(base.name, suffix: "Smoother")
        result.goal = "Reduce harshness: cut energy across the 5–9 kHz fatigue region."
        result.safety.autoGainEnabled = false
        result = result.normalized()

        let validation = validator.validate(result)
        result.safety.clippingRisk = validation.clippingRisk

        let changes = diff(from: base, to: result, curve: nil)
        result.correction = CorrectionMetadata(
            role: .preference,
            baselinePresetId: base.id,
            source: "Quick action: reduce harshness",
            sourceConfidence: .unknown,
            correctionStrength: base.correction?.correctionStrength ?? 1,
            targetCurveId: base.correction?.targetCurveId,
            targetBlend: base.correction?.targetBlend ?? 1,
            preferenceBandIndexes: changes.map(\.bandIndex)
        )
        return TuningResult(
            preset: result,
            intent: ["Tame harsh, fatiguing treble in the 5–9 kHz region"],
            changes: changes,
            validation: validation,
            basis: "Quick action: reduce harshness"
        )
    }

    // MARK: - Internal move model

    /// An intermediate, pre-clamp tuning move. Keeping moves separate from
    /// `EQBand` lets us merge overlapping suggestions and attach rationales
    /// before we lay them out into the 20 fixed slots.
    private struct Move: Equatable {
        var type: BandType
        var frequencyHz: Double
        var gainDb: Double
        var q: Double
        var rationale: String
    }

    // MARK: Resolution of inputs

    private func resolveProfile(_ request: AITuningRequest) -> HeadphoneProfile? {
        guard let name = request.headphone, !name.isEmpty else { return nil }
        return knowledge.profile(id: name) ?? knowledge.profileMatching(name)
    }

    /// Resolves the target curve from the explicit id, then the headphone's
    /// suggested curve, then keyword inference from the goal text.
    private func resolveCurve(_ request: AITuningRequest, profile: HeadphoneProfile?) -> TargetCurve? {
        if let id = request.targetCurveId, let c = knowledge.targetCurve(id: id) {
            return c
        }
        if let inferred = inferCurveId(from: request.goalText), let c = knowledge.targetCurve(id: inferred) {
            return c
        }
        if let suggested = profile?.suggestedTargetCurveId, let c = knowledge.targetCurve(id: suggested) {
            // Only fall back to the headphone's suggestion when the user gave no
            // direction at all (no curve id and no goal text).
            if request.targetCurveId == nil && (request.goalText?.isEmpty ?? true) {
                return c
            }
        }
        return nil
    }

    /// Maps free-text goal keywords to a known curve id. Deterministic and
    /// order-stable: the first keyword group that hits wins.
    private func inferCurveId(from goalText: String?) -> String? {
        guard let text = goalText?.lowercased(), !text.isEmpty else { return nil }
        // Ordered so more specific intents win over generic ones.
        let table: [(keywords: [String], curveId: String)] = [
            (["footstep", "fps", "competitive", "shooter", "발소리", "게이밍", "게임", "슈터", "경쟁"], "fps-footstep"),
            (["podcast", "speech", "spoken", "audiobook", "voice", "팟캐스트", "말소리", "목소리", "오디오북", "강의"], "podcast"),
            (["late", "night", "quiet", "low volume", "relax", "밤", "야간", "조용", "작게", "편안", "부드럽"], "late-night"),
            (["vocal", "voice", "singer", "보컬", "목소리", "가수", "노래"], "vocal-focus"),
            (["bass", "sub", "rumble", "hip hop", "hip-hop", "edm", "electronic", "저음", "베이스", "서브", "킥", "묵직"], "bass-boost"),
            (["rock", "metal", "guitar", "punch", "punchy", "락", "록", "메탈", "기타", "펀치"], "rock"),
            (["crinacle", "crinacle target", "ief 2025", "ief preference", "in-ear fidelity", "jm-1", "크리나클", "크리나클 타겟", "크리나클 타깃", "인이어 피델리티"], "crinacle-ief-2025"),
            (["neutral", "reference", "harman", "accurate", "balanced", "flat", "중립", "뉴트럴", "하만", "밸런스", "균형", "플랫"], "harman-neutral"),
            (["warm", "warmer", "body", "따뜻", "온기", "두툼", "포근", "바디"], "harman-neutral")
        ]
        for entry in table where entry.keywords.contains(where: { text.contains($0) }) {
            return entry.curveId
        }
        return nil
    }

    private func goalLabel(_ request: AITuningRequest, curve: TargetCurve?) -> String {
        if let curve { return curve.name }
        if let goal = request.goalText, !goal.isEmpty {
            // Use the leading clause as a short label.
            let firstClause = goal.split(whereSeparator: { ":–—-,.".contains($0) }).first
            let trimmed = firstClause.map { $0.trimmingCharacters(in: .whitespaces) } ?? goal
            return trimmed.isEmpty ? "Custom" : trimmed.capitalizedFirst
        }
        return "Custom"
    }

    // MARK: Move construction

    /// The starting set of moves: target-curve hints if a curve resolved,
    /// otherwise keyword-derived moves from the goal text, otherwise empty.
    private func baseMoves(request: AITuningRequest, curve: TargetCurve?) -> [Move] {
        let targetBlend = min(max(request.targetBlend, 0), 1)
        if let curve {
            return curve.hints.map {
                Move(type: $0.type, frequencyHz: $0.frequencyHz, gainDb: $0.gainDb * targetBlend, q: $0.q, rationale: $0.rationale)
            }
        }
        return scale(keywordMoves(from: request.goalText), by: targetBlend) + keywordMoves(from: request.preference)
    }

    /// Derives moves directly from free-text keywords when no curve is available.
    /// Each keyword contributes a small, well-understood move; duplicates are
    /// merged later in `materialize`.
    private func keywordMoves(from text: String?) -> [Move] {
        guard let t = text?.lowercased(), !t.isEmpty else { return [] }
        var out: [Move] = []
        func has(_ ks: String...) -> Bool { ks.contains { t.contains($0) } }

        if has("bass", "sub", "rumble", "kick", "punch", "punchy", "저음", "베이스", "서브", "킥", "묵직", "펀치") {
            out.append(Move(type: .lowShelf, frequencyHz: 80, gainDb: 3.0, q: 0.7,
                            rationale: "Add low-end weight and punch."))
        }
        if has("vocal", "voice", "singer", "보컬", "목소리", "가수", "노래", "선명", "명료") {
            out.append(Move(type: .bell, frequencyHz: 3000, gainDb: 2.0, q: 1.2,
                            rationale: "Bring the vocal presence forward."))
        }
        if has("rock", "metal", "guitar", "락", "록", "메탈", "기타") {
            out.append(Move(type: .bell, frequencyHz: 4000, gainDb: 2.0, q: 1.5,
                            rationale: "Add bite to guitars and snare."))
        }
        if has("bright", "brighter", "air", "sparkle", "detail", "밝", "공기감", "디테일", "해상도", "반짝") {
            out.append(Move(type: .high_shelf_alias, frequencyHz: 10000, gainDb: 2.0, q: 0.7,
                            rationale: "Add air and brightness up top."))
        }
        if has("warm", "warmer", "smooth", "darker", "따뜻", "온기", "두툼", "포근", "부드럽", "어둡", "바디") {
            out.append(Move(type: .lowShelf, frequencyHz: 120, gainDb: 2.0, q: 0.7,
                            rationale: "Add warmth and body in the low end."))
            out.append(Move(type: .bell, frequencyHz: 7000, gainDb: -1.5, q: 1.5,
                            rationale: "Soften upper treble for a smoother tone."))
        }
        if has("footstep", "fps", "competitive", "발소리", "게이밍", "게임", "슈터", "경쟁") {
            out.append(Move(type: .bell, frequencyHz: 3500, gainDb: 3.0, q: 1.5,
                            rationale: "Emphasize footstep cues for positional clarity."))
        }
        if has("late", "night", "quiet", "밤", "야간", "조용", "작게", "편안") {
            out.append(Move(type: .lowShelf, frequencyHz: 100, gainDb: 2.0, q: 0.7,
                            rationale: "Restore perceived bass at low volume."))
            out.append(Move(type: .bell, frequencyHz: 7000, gainDb: -2.5, q: 1.5,
                            rationale: "Reduce fatiguing treble for late-night listening."))
        }
        return out
    }

    /// Scales/adjusts moves using the headphone's correction profile: harsh
    /// regions get extra restraint (or a small dedicated cut when the user wants
    /// to avoid harsh treble), and obviously bass-light cans get a touch more low
    /// shelf headroom.
    private func applyHeadphoneCorrections(
        _ moves: [Move],
        profile: HeadphoneProfile?,
        request: AITuningRequest,
        correctionStrength: Double
    ) -> [Move] {
        guard let profile else { return moves }
        let strength = min(max(correctionStrength, 0), 1)
        guard strength > 0 else { return moves }
        var out = moves

        // For each harsh region, pull down any boosting move that lands inside it,
        // and (when avoiding harsh treble) add a gentle corrective cut centered on
        // the region.
        for region in profile.harshRegionsHz {
            let center = region.centerHz
            for i in out.indices {
                if out[i].frequencyHz >= region.lowHz, out[i].frequencyHz <= region.highHz, out[i].gainDb > 0 {
                    // Halve boosts that fall in a known-harsh region.
                    out[i].gainDb *= (1 - 0.5 * strength)
                    out[i].rationale += " (eased — \(profile.model) is hot here)"
                }
            }
            if request.avoidHarshTreble {
                out = mergeIn(out, Move(type: .bell, frequencyHz: center, gainDb: -2.0 * strength, q: 2.0,
                                        rationale: "Tame \(profile.model)'s harsh region near \(Int(center.rounded())) Hz."))
            }
        }

        // If the headphone is described as bass-light/rolled-off and the tuning
        // already adds a low shelf, give it a small extra nudge for body.
        let notes = profile.correctionNotes.joined(separator: " ").lowercased()
        if notes.contains("roll") || notes.contains("light bass") || notes.contains("bass-light") {
            for i in out.indices where (out[i].type == .lowShelf) && out[i].gainDb > 0 {
                out[i].gainDb += 1.0 * strength
                out[i].rationale += " (extra — \(profile.model) is bass-light)"
            }
        }
        return out
    }

    /// Applies the free-text preference as small directional nudges on top of the
    /// resolved moves (e.g. "brighter guitars, a bit more kick").
    private func applyPreferenceNudges(_ moves: [Move], request: AITuningRequest) -> [Move] {
        guard let pref = request.preference?.lowercased(), !pref.isEmpty else { return moves }
        var out = moves
        func wants(_ ks: String...) -> Bool { ks.contains { pref.contains($0) } }

        if wants("more bass", "more kick", "more low", "more sub", "punch", "punchier",
                 "저음 더", "베이스 더", "킥 더", "더 묵직", "펀치") {
            out = mergeIn(out, Move(type: .lowShelf, frequencyHz: 80, gainDb: 2.0, q: 0.7,
                                    rationale: "Preference: add low-end punch."))
        }
        if wants("less bass", "boomy", "too much bass", "less low",
                 "저음 줄", "베이스 줄", "붕붕", "부밍", "과한 저음") {
            out = mergeIn(out, Move(type: .lowShelf, frequencyHz: 80, gainDb: -2.0, q: 0.7,
                                    rationale: "Preference: reduce boomy low end."))
        }
        if wants("brighter", "more air", "more detail", "more treble", "more sparkle",
                 "더 밝", "공기감", "디테일", "해상도", "고음 더") {
            out = mergeIn(out, Move(type: .highShelf, frequencyHz: 10000, gainDb: 1.5, q: 0.7,
                                    rationale: "Preference: add brightness and air."))
        }
        if wants("darker", "less treble", "less bright", "smoother", "less harsh",
                 "고음 줄", "덜 밝", "부드럽", "쏘", "날카", "거칠", "치찰", "자극", "피곤") {
            out = mergeIn(out, Move(type: .bell, frequencyHz: 7000, gainDb: -2.0, q: 1.5,
                                    rationale: "Preference: soften the treble."))
        }
        if wants("more vocal", "keep vocal", "clearer vocal", "forward vocal",
                 "보컬 더", "보컬 선명", "목소리 선명", "보컬 앞으로", "명료") {
            out = mergeIn(out, Move(type: .bell, frequencyHz: 3000, gainDb: 1.5, q: 1.2,
                                    rationale: "Preference: keep vocals clear and forward."))
        }
        if wants("warmer", "warm", "따뜻", "온기", "두툼", "포근") {
            out = mergeIn(out, Move(type: .lowShelf, frequencyHz: 120, gainDb: 1.5, q: 0.7,
                                    rationale: "Preference: warmer tone."))
        }
        return out
    }

    private func scale(_ moves: [Move], by amount: Double) -> [Move] {
        let clamped = min(max(amount, 0), 1)
        guard clamped < 0.999 else { return moves }
        return moves.map {
            Move(
                type: $0.type,
                frequencyHz: $0.frequencyHz,
                gainDb: $0.gainDb * clamped,
                q: $0.q,
                rationale: $0.rationale
            )
        }
    }

    // MARK: Materialization

    /// Folds overlapping moves together, clamps gains to the boost ceiling and
    /// (when avoiding harsh treble) drops positive boosts in the 5–9 kHz region,
    /// then lays the result out into 20 ordered bands by ascending frequency.
    private func materialize(_ moves: [Move], maxBoost: Double, avoidHarshTreble: Bool) -> [EQBand] {
        // Merge moves that share the same type + (rounded) frequency by summing
        // their gains and averaging their Q — deterministic, order-independent.
        var merged: [Move] = []
        for m in moves {
            if let idx = merged.firstIndex(where: { $0.type == m.type && Self.freqKey($0.frequencyHz) == Self.freqKey(m.frequencyHz) }) {
                merged[idx].gainDb += m.gainDb
                merged[idx].q = (merged[idx].q + m.q) / 2
                if !m.rationale.isEmpty {
                    merged[idx].rationale = m.rationale
                }
            } else {
                merged.append(m)
            }
        }

        // Apply harsh-treble avoidance and the boost ceiling.
        var prepared: [Move] = []
        for var m in merged {
            if avoidHarshTreble, m.gainDb > 0, m.frequencyHz >= 5000, m.frequencyHz <= 9000 {
                // Don't push energy into the fatigue band — drop the boost.
                continue
            }
            if m.gainDb > 0 {
                m.gainDb = min(m.gainDb, maxBoost)
            }
            // Skip no-op moves entirely (keeps slot count down).
            if m.type.usesGain && abs(m.gainDb) < 0.1 { continue }
            prepared.append(m)
        }

        // Sort with explicit tie-breakers so equal-frequency moves remain
        // byte-identical across standard-library implementations.
        prepared.sort(by: Self.moveComesBefore)
        if prepared.count > EQBand.bandCount {
            prepared = Array(prepared.prefix(EQBand.bandCount))
        }

        // Lay out enabled bands first, fill the remainder with empty slots.
        var bands: [EQBand] = []
        for (i, m) in prepared.enumerated() {
            let band = EQBand(
                index: i + 1,
                type: m.type,
                frequencyHz: m.frequencyHz,
                gainDb: m.gainDb,
                q: m.q,
                channel: .stereo,
                enabled: true
            ).clamped()
            bands.append(band)
        }
        if prepared.count < EQBand.bandCount {
            for i in (prepared.count + 1)...EQBand.bandCount {
                bands.append(EQBand.emptyBand(index: i))
            }
        }
        return bands
    }

    /// Rounds a frequency to a coarse key so near-identical moves merge.
    private static func freqKey(_ hz: Double) -> Int { Int((hz / 5).rounded()) }

    private static func moveComesBefore(_ lhs: Move, _ rhs: Move) -> Bool {
        if lhs.frequencyHz != rhs.frequencyHz { return lhs.frequencyHz < rhs.frequencyHz }
        if lhs.type.rawValue != rhs.type.rawValue { return lhs.type.rawValue < rhs.type.rawValue }
        if lhs.gainDb != rhs.gainDb { return lhs.gainDb < rhs.gainDb }
        if lhs.q != rhs.q { return lhs.q < rhs.q }
        return lhs.rationale < rhs.rationale
    }

    /// Keeps every active band from the existing preset in its original slot,
    /// then fills only disabled slots with newly generated target/preference
    /// moves. When all 20 slots are occupied, preserving the baseline wins over
    /// adding another move.
    private func compose(basePreset: EQPreset?, base: EQPreset, generatedBands: [EQBand]) -> [EQBand] {
        guard basePreset != nil else { return generatedBands }

        var composed = base.bands
        let availableSlots = composed.indices.filter { !composed[$0].enabled }
        let additions = generatedBands.filter(\.enabled)

        for (slot, addition) in zip(availableSlots, additions) {
            var inserted = addition
            inserted.index = composed[slot].index
            composed[slot] = inserted
        }
        return composed
    }

    // MARK: Safety ceiling

    private func effectiveMaxBoost(request: AITuningRequest, rules: SafetyRules) -> Double {
        let shipped = rules.maxBoostDb
        guard let requested = request.maxBoostDb else { return shipped }
        // The request may only tighten the ceiling, never exceed the shipped one.
        return max(0, min(shipped, requested))
    }

    /// Existing correction metadata is authoritative when layering on a
    /// baseline. Otherwise, use the resolved profile's evidence quality.
    private func effectiveSourceConfidence(
        base: EQPreset,
        profile: HeadphoneProfile?
    ) -> CorrectionSourceConfidence {
        if hasBaseline(base) {
            return base.correction?.sourceConfidence ?? .unknown
        }
        return correctionConfidence(from: profile?.credibility)
    }

    /// Unmeasured or explicitly estimated model correction must remain gentle.
    /// Target-curve blend and subjective preference moves are separate controls
    /// and are intentionally not scaled by this cap.
    private func conservativeCorrectionStrength(
        _ requested: Double,
        confidence: CorrectionSourceConfidence
    ) -> Double {
        let clamped = min(max(requested, 0), 1)
        switch confidence {
        case .estimated, .unknown:
            return min(clamped, 0.5)
        case .measured, .manufacturer, .community:
            return clamped
        }
    }

    private func hasBaseline(_ preset: EQPreset) -> Bool {
        !preset.activeBands.isEmpty && preset.id != EQPreset.flat().id
    }

    // MARK: Naming / ids / tags

    private func presetName(profile: HeadphoneProfile?, goal: String) -> String {
        if let hp = profile?.displayName {
            return "\(hp) – \(goal)"
        }
        return goal
    }

    /// Deterministic id derived from the headphone + goal (slugified). The
    /// persistence layer reassigns a unique id on save; this keeps repeated
    /// in-memory tunings stable.
    private func derivedId(profile: HeadphoneProfile?, goal: String) -> String {
        let hp = profile?.id ?? "generic"
        return "ai_\(hp)_\(Self.slug(goal))"
    }

    private func tags(curve: TargetCurve?, profile: HeadphoneProfile?) -> [String] {
        var t: [String] = ["ai"]
        if let curve { t.append(curve.id) }
        if let profile { t.append(profile.id) }
        return t
    }

    private static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Explanations

    private func intentSummary(curve: TargetCurve?, profile: HeadphoneProfile?, request: AITuningRequest) -> String {
        if let goal = request.goalText, !goal.isEmpty { return goal }
        if let curve { return curve.description }
        return "Custom tuning."
    }

    private func intentBullets(curve: TargetCurve?, profile: HeadphoneProfile?, request: AITuningRequest) -> [String] {
        var bullets: [String] = []
        if let curve {
            bullets.append("Apply the \(curve.name) target: \(curve.description)")
        } else if let goal = request.goalText, !goal.isEmpty {
            bullets.append("Goal: \(goal)")
        }
        if let profile {
            bullets.append("Adapted to \(profile.displayName): \(profile.signature)")
            if request.avoidHarshTreble, !profile.harshRegionsHz.isEmpty {
                bullets.append("Avoided \(profile.model)'s known harsh regions.")
            }
        }
        if let pref = request.preference, !pref.isEmpty {
            bullets.append("Honored your preference: \(pref)")
        }
        if bullets.isEmpty {
            bullets.append("Custom tuning within safety limits.")
        }
        return bullets
    }

    private func basisString(profile: HeadphoneProfile?, curve: TargetCurve?) -> String {
        var parts: [String] = []
        if let profile { parts.append("\(profile.displayName) (\(profile.credibility.displayName))") }
        if let curve { parts.append("\(curve.name) target curve") }
        return parts.isEmpty ? "Deterministic tuning engine" : parts.joined(separator: " + ")
    }

    /// Builds the per-band change list by comparing each slot of `to` against the
    /// same slot of `from`. Only meaningfully-changed bands are reported.
    private func diff(from base: EQPreset, to result: EQPreset, curve: TargetCurve?) -> [TuningChange] {
        var changes: [TuningChange] = []
        let baseByIndex = Dictionary(uniqueKeysWithValues: base.bands.map { ($0.index, $0) })

        for band in result.bands.sorted(by: {
            if $0.frequencyHz != $1.frequencyHz { return $0.frequencyHz < $1.frequencyHz }
            return $0.index < $1.index
        }) {
            let before = baseByIndex[band.index]
            let changed = bandChanged(before: before, after: band)
            guard changed else { continue }
            let summary = changeSummary(band)
            let rationale = rationale(for: band, curve: curve)
            changes.append(TuningChange(bandIndex: band.index, summary: summary, rationale: rationale))
        }
        return changes
    }

    private func bandChanged(before: EQBand?, after: EQBand) -> Bool {
        // A newly-active band, or one whose audible parameters moved.
        guard let before else { return after.enabled }
        if before.enabled != after.enabled { return after.enabled || before.enabled }
        if !after.enabled { return false }
        if before.type != after.type { return true }
        if abs(before.frequencyHz - after.frequencyHz) > 0.5 { return true }
        if abs(before.gainDb - after.gainDb) > 0.05 { return true }
        if abs(before.q - after.q) > 0.05 { return true }
        return false
    }

    private func changeSummary(_ band: EQBand) -> String {
        let freq = formatHz(band.frequencyHz)
        let shape = "\(band.type.qDisplayName) \(formatQ(band.q))"
        if band.type.usesGain {
            let sign = band.gainDb >= 0 ? "+" : ""
            return "\(band.type.displayName) \(sign)\(formatDb(band.gainDb)) dB at \(freq), \(shape)"
        } else {
            return "\(band.type.displayName) at \(freq), \(shape)"
        }
    }

    private func rationale(for band: EQBand, curve: TargetCurve?) -> String {
        // Prefer a matching curve hint's rationale; otherwise describe by region.
        if let curve, let hint = curve.hints.min(by: { abs($0.frequencyHz - band.frequencyHz) < abs($1.frequencyHz - band.frequencyHz) }),
           abs(hint.frequencyHz - band.frequencyHz) <= hint.frequencyHz * 0.25, !hint.rationale.isEmpty {
            return hint.rationale
        }
        return regionRationale(frequencyHz: band.frequencyHz, gainDb: band.gainDb, usesGain: band.type.usesGain)
    }

    /// A plain-language reason inferred purely from where the move sits.
    private func regionRationale(frequencyHz: Double, gainDb: Double, usesGain: Bool) -> String {
        let boosting = gainDb >= 0
        switch frequencyHz {
        case ..<60:    return boosting ? "Deepen sub-bass rumble." : "Tighten sub-bass."
        case ..<150:   return boosting ? "Add low-end punch and warmth." : "Reduce low-end boom."
        case ..<400:   return boosting ? "Fill out the lower mids." : "Clear low-mid muddiness."
        case ..<1200:  return boosting ? "Add body to mids and vocals." : "Reduce mid honkiness."
        case ..<2500:  return boosting ? "Bring instruments and vocals forward." : "Soften forward mids."
        case ..<5000:  return boosting ? "Add presence and clarity." : "Reduce presence harshness."
        case ..<9000:  return boosting ? "Add detail and edge." : "Tame fatiguing treble in the 5–9 kHz region."
        default:       return boosting ? "Add air and sparkle up top." : "Roll off the very top end."
        }
    }

    private func correctionMetadata(
        request: AITuningRequest,
        profile: HeadphoneProfile?,
        curve: TargetCurve?,
        base: EQPreset,
        sourceConfidence: CorrectionSourceConfidence,
        appliedCorrectionStrength: Double,
        changedBandIndexes: [Int]
    ) -> CorrectionMetadata {
        let hasBaseline = hasBaseline(base)
        let hasTargetOrProfileMoves = curve != nil || profile != nil
        let role: CorrectionRole
        if hasBaseline {
            role = hasTargetOrProfileMoves ? .combined : .preference
        } else {
            role = .baseline
        }

        let source: String?
        if hasBaseline, let baselineSource = base.correction?.source {
            source = baselineSource
        } else if profile?.source.isEmpty == false {
            source = profile?.source
        } else {
            source = curve.map { "Target curve: \($0.name)" }
        }

        return CorrectionMetadata(
            role: role,
            baselinePresetId: hasBaseline ? (base.correction?.baselinePresetId ?? base.id) : nil,
            source: source,
            sourceConfidence: sourceConfidence,
            correctionStrength: appliedCorrectionStrength,
            targetCurveId: curve?.id,
            targetBlend: request.targetBlend,
            preferenceBandIndexes: hasBaseline ? changedBandIndexes : []
        )
    }

    private func correctionConfidence(from credibility: Credibility?) -> CorrectionSourceConfidence {
        switch credibility {
        case .measured: return .measured
        case .manufacturer: return .manufacturer
        case .community: return .community
        case .estimated: return .estimated
        case nil: return .unknown
        }
    }

    // MARK: Working from an existing preset

    /// Reconstructs the move list from a preset's active, gain-using bands so the
    /// quick actions can layer changes deterministically on top.
    private func movesFromPreset(_ preset: EQPreset) -> [Move] {
        preset.bands
            .filter { $0.enabled }
            .map { Move(type: $0.type, frequencyHz: $0.frequencyHz, gainDb: $0.gainDb, q: $0.q, rationale: "") }
    }

    /// Merges a single move into a list, summing onto an existing same-type,
    /// same-frequency move rather than appending a duplicate.
    private func mergeIn(_ moves: [Move], _ move: Move) -> [Move] {
        var out = moves
        if let idx = out.firstIndex(where: { $0.type == move.type && Self.freqKey($0.frequencyHz) == Self.freqKey(move.frequencyHz) }) {
            out[idx].gainDb += move.gainDb
            out[idx].q = (out[idx].q + move.q) / 2
            if !move.rationale.isEmpty { out[idx].rationale = move.rationale }
        } else {
            out.append(move)
        }
        return out
    }

    /// The cut centers used by `reduceHarshness`: the named headphone's harsh
    /// regions if known, otherwise the canonical 5–9 kHz fatigue band.
    private func harshCenters(for headphone: String?) -> [Double] {
        if let name = headphone,
           let profile = knowledge.profile(id: name) ?? knowledge.profileMatching(name),
           !profile.harshRegionsHz.isEmpty {
            return profile.harshRegionsHz.map { $0.centerHz }
        }
        return [6000, 7500]
    }

    private func appendSuffix(_ name: String, suffix: String) -> String {
        name.contains(suffix) ? name : "\(name) (\(suffix))"
    }

    // MARK: Number formatting (locale-independent for determinism)

    private func formatHz(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            // Trim trailing zero (e.g. 10.0k → 10k, 3.5k stays).
            let s = String(format: "%.1f", k)
            let trimmed = s.hasSuffix(".0") ? String(s.dropLast(2)) : s
            return "\(trimmed) kHz"
        }
        return "\(Int(hz.rounded())) Hz"
    }

    private func formatDb(_ db: Double) -> String {
        String(format: "%.1f", db)
    }

    private func formatQ(_ q: Double) -> String {
        String(format: "%.2f", q)
    }
}

// MARK: - Small helpers

private extension BandType {
    /// Alias used in keyword construction to keep the source readable; identical
    /// to `.highShelf`.
    static var high_shelf_alias: BandType { .highShelf }
}

private extension String {
    /// Capitalizes only the first character, leaving the rest untouched (so
    /// "rock vibes" → "Rock vibes" rather than title-casing everything).
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
