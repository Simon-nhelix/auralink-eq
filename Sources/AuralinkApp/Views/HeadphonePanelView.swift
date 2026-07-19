import SwiftUI
import AuralinkCore

/// Right-side "Headphone" panel.
///
/// Shows the tonal profile for the current preset's assigned headphone — its
/// signature, correction notes, harsh regions, and the source + credibility so
/// the user can judge how much to trust it. Below the profile is a pick list of
/// every known headphone so the user can re-assign the current preset's target
/// can (which seeds the AI tuner's starting point).
struct HeadphonePanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                header
                if let profile = currentProfile {
                    profileCard(profile)
                } else {
                    noProfileCard
                }
                activeTuningCard
                presetList
                pickList
            }
            .padding(Theme.Metrics.pad)
        }
        .background(Theme.Palette.bg)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Gradients.aura)
            Text("Headphone")
                .font(Theme.Typo.title)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    // MARK: Profile card

    private func profileCard(_ profile: HeadphoneProfile) -> some View {
        AuraCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.pad) {
                // Title + type + credibility
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.displayName)
                        .font(Theme.Typo.title)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    HStack(spacing: 6) {
                        AuraTag(PresetFormatting.typeLabel(profile.type), tint: Theme.Palette.auraBlue)
                        AuraTag(profile.credibility.displayName, tint: PresetFormatting.credibilityTint(profile.credibility))
                    }
                }

                // Signature
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Signature")
                    Text(profile.signature)
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Correction notes
                if !profile.correctionNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Correction notes")
                        ForEach(Array(profile.correctionNotes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Theme.Palette.accent)
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)
                                Text(note)
                                    .font(Theme.Typo.body)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                // Harsh regions
                if !profile.harshRegionsHz.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Harsh regions")
                        FlowTags(items: profile.harshRegionsHz.map { PresetFormatting.harshLabel($0) },
                                 tint: Theme.Palette.warning)
                    }
                }

                // Suggested curve
                if let curveId = profile.suggestedTargetCurveId,
                   let curve = model.targetCurves.first(where: { $0.id == curveId }) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Suggested target")
                        AuraTag(curve.name, tint: Theme.Palette.auraViolet)
                    }
                }

                // Source
                if !profile.source.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Source")
                        Text(profile.source)
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var noProfileCard: some View {
        AuraCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("No headphone assigned")
                    .font(Theme.Typo.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Pick a headphone below to load a visible baseline correction. The graph and active band table will update immediately.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activeTuningCard: some View {
        AuraCard(padding: Theme.Metrics.padSm) {
            HStack(spacing: Theme.Metrics.gap) {
                Image(systemName: model.currentPreset.activeBands.isEmpty ? "circle" : "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.currentPreset.activeBands.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentPreset.name)
                        .font(Theme.Typo.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(model.currentPreset.activeBands.count) active bands · preamp \(Fmt.db(model.currentPreset.preampDb))")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var presetList: some View {
        let presets = model.presets(for: currentProfile)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(currentProfile == nil ? "Generic Presets" : "Presets for this headphone")
                Spacer()
                Text("\(presets.count)")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            if presets.isEmpty {
                AuraCard(padding: Theme.Metrics.padSm) {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text("No saved presets for this model yet.")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(presets) { preset in
                        presetRow(preset)
                    }
                }
            }
        }
    }

    private func presetRow(_ preset: EQPreset) -> some View {
        let isCurrent = preset.id == model.currentPreset.id
        return Button {
            model.load(preset: preset)
        } label: {
            HStack(alignment: .center, spacing: Theme.Metrics.gap) {
                Image(systemName: isCurrent ? "largecircle.fill.circle" : presetIcon(preset))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(preset.name)
                            .font(Theme.Typo.label)
                            .foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textPrimary)
                            .lineLimit(1)
                        if preset.createdBy == .ai {
                            AuraTag("AI", tint: Theme.Palette.auraViolet)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("\(preset.activeBands.count) bands")
                        Text("preamp \(Fmt.db(preset.preampDb))")
                        if let correction = preset.correction {
                            Text(PresetFormatting.roleTag(correction.role))
                            if correction.sourceConfidence != .unknown {
                                Text(correction.sourceConfidence.rawValue)
                            }
                        } else if preset.tags.contains("baseline") {
                            Text("baseline")
                        } else if preset.tags.contains("audition") {
                            Text("audition")
                        }
                    }
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    StatusDot(color: Theme.Palette.accent, label: "Loaded", glow: true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(isCurrent ? Theme.Palette.surfaceHi : Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .strokeBorder(isCurrent ? Theme.Palette.accent.opacity(0.4) : Theme.Palette.line,
                                          lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func presetIcon(_ preset: EQPreset) -> String {
        preset.createdBy == .ai ? "sparkles" : "slider.horizontal.3"
    }

    // MARK: Pick list

    private var pickList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Assign headphone")
            VStack(spacing: 6) {
                pickRow(name: nil, isSelected: assignedId == nil)
                ForEach(model.headphoneProfiles) { profile in
                    pickRow(name: profile.displayName,
                            profile: profile,
                            type: profile.type,
                            isSelected: assignedId == profile.id)
                }
            }
            Text("Selecting a model applies a saved or newly generated baseline correction, so the response curve changes right away.")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func pickRow(name: String?, profile: HeadphoneProfile? = nil, type: HeadphoneType? = nil, isSelected: Bool) -> some View {
        Button {
            model.applyHeadphoneProfile(profile)
        } label: {
            HStack(spacing: Theme.Metrics.gap) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                Text(name ?? "Generic / none")
                    .font(Theme.Typo.body)
                    .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                Spacer(minLength: 0)
                if let type {
                    Text(PresetFormatting.typeLabel(type))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(isSelected ? Theme.Palette.surfaceHi : Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .strokeBorder(isSelected ? Theme.Palette.accent.opacity(0.4) : Theme.Palette.line,
                                          lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Logic

    private var currentProfile: HeadphoneProfile? {
        model.headphoneProfile(named: model.currentPreset.headphone)
    }

    /// The id of the currently-assigned profile (via fuzzy match), if any.
    private var assignedId: String? {
        currentProfile?.id
    }
}
