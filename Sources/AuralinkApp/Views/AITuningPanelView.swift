import AuralinkLocalization
import SwiftUI
import AuralinkCore

/// Right-side "AI Tuning" panel (plan §6.3).
///
/// Collects a natural-language tuning request — headphone, goal/target curve,
/// a free-text preference, and the safety envelope — then hands it to the
/// deterministic in-app `TuningEngine` via `model.requestTuning`. The result
/// lands in `model.pendingProposal`, which `AIResultView` renders as an overlay.
///
/// Everything here is *input collection*: it never mutates the preset itself.
/// That keeps the "describe → review → apply" loop the product is built around.
struct AITuningPanelView: View {
    @EnvironmentObject var model: AppModel

    // Local form state. Seeded from the current preset / knowledge on appear so
    // the panel feels continuous with whatever the user is already auditioning.
    @State private var headphoneId: String = ""
    @State private var targetCurveId: String = ""
    @State private var preference: String = ""
    @State private var maxBoostDb: Double = 6
    @State private var correctionStrength: Double = 0.7
    @State private var targetBlend: Double = 0.85
    @State private var avoidHarshTreble: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.pad) {
                headphoneSection
                Divider().overlay(Theme.Palette.line)
                goalSection
                Divider().overlay(Theme.Palette.line)
                strengthSection
                Divider().overlay(Theme.Palette.line)
                preferenceSection
                Divider().overlay(Theme.Palette.line)
                safetySection
                Divider().overlay(Theme.Palette.line)
                generateButton
                quickActions
            }
            .padding(Theme.Metrics.pad)
        }
        .background(Theme.Palette.bg)
        .onAppear(perform: seedFromModel)
        .onChange(of: model.currentPreset.headphone) { _, _ in
            seedFromModel()
        }
        .onChange(of: model.currentPreset.id) { _, _ in
            seedFromModel()
        }
        .onChange(of: headphoneId) { _, newValue in
            guard let suggested = model.headphoneProfiles.first(where: { $0.id == newValue })?.suggestedTargetCurveId,
                  model.targetCurves.contains(where: { $0.id == suggested }) else { return }
            targetCurveId = suggested
        }
    }

    // MARK: Headphone

    private var headphoneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            inspectorHeading(L10n.text("Headphone"), systemImage: "headphones")
            Picker(L10n.text("Headphone"), selection: $headphoneId) {
                Text(L10n.text("Generic / none")).tag("")
                ForEach(model.headphoneProfiles) { profile in
                    Text(profile.displayName).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.Palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Goal / target curve

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            inspectorHeading(L10n.text("Goal"), systemImage: "scope")
            Picker(L10n.text("Goal"), selection: $targetCurveId) {
                ForEach(model.targetCurves) { curve in
                    Text(curve.name).tag(curve.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.Palette.accent)

            if let curve = selectedCurve {
                HStack(spacing: 6) {
                    AuraTag(L10n.text(curve.category.displayName))
                    Spacer(minLength: 0)
                }
                Text(curve.description)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(3)
            }
        }
    }

    // MARK: Strength

    private var strengthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorHeading(L10n.text("Strength"), systemImage: "gauge.with.dots.needle.33percent")
            strengthRow(L10n.text("Correction"), value: $correctionStrength, tint: Theme.Palette.accent)
            strengthRow(L10n.text("Target blend"), value: $targetBlend, tint: Theme.Palette.accent)
        }
    }

    private func strengthRow(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 92, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05)
                .tint(tint)
            Text(PresetFormatting.percent(value.wrappedValue))
                .font(Theme.Typo.mono)
                .foregroundStyle(tint)
                .frame(width: 42, alignment: .trailing)
        }
    }

    // MARK: Preference

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            inspectorHeading(L10n.text("Preference"), systemImage: "slider.horizontal.3")
            TextField(L10n.text("e.g. keep vocals, brighter guitars, a bit more kick"),
                      text: $preference, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1...3)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                                .strokeBorder(Theme.Palette.line, lineWidth: 1)
                        )
                )
        }
    }

    // MARK: Safety

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorHeading(L10n.text("Safety"), systemImage: "shield")

            HStack {
                Text(L10n.text("Max boost"))
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(Fmt.db(maxBoostDb))
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.Palette.accent)
                Stepper(L10n.text("Max boost"), value: $maxBoostDb, in: 0...18, step: 0.5)
                    .labelsHidden()
            }

            Toggle(isOn: $avoidHarshTreble) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Avoid harsh treble"))
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(L10n.text("Prefer cuts over boosts in the 5–9 kHz fatigue region."))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)

        }
    }

    // MARK: Generate

    private var generateButton: some View {
        Button(action: generate) {
            HStack(spacing: 8) {
                if model.isTuning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.Palette.textOnAccent)
                    Text(L10n.text("Generating…"))
                } else {
                    Image(systemName: "wand.and.stars")
                    Text(L10n.text("Generate Tuning"))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraButtonStyle(prominent: true))
        .disabled(model.isTuning)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: Theme.Metrics.gap) {
                Button {
                    model.makeWarmer()
                } label: {
                    Text(L10n.text("Warmer"))
                        .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)

                Button {
                    model.reduceHarshness()
                } label: {
                    Text(L10n.text("Reduce harshness"))
                        .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .disabled(model.isTuning)
        }
    }

    private func inspectorHeading(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 18)
            Text(title)
                .font(Theme.Typo.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    // MARK: Logic

    private var selectedCurve: TargetCurve? {
        model.targetCurves.first { $0.id == targetCurveId }
    }

    private func seedFromModel() {
        // Prefer the current preset's headphone; fall back to nothing.
        if let hp = model.currentPreset.headphone,
           let match = model.headphoneProfile(named: hp) {
            headphoneId = match.id
        } else {
            headphoneId = ""
        }
        // Default goal: the headphone's suggested curve, else the first available.
        if targetCurveId.isEmpty {
            let suggested = model.headphoneProfiles.first { $0.id == headphoneId }?.suggestedTargetCurveId
            if let suggested, model.targetCurves.contains(where: { $0.id == suggested }) {
                targetCurveId = suggested
            } else {
                targetCurveId = model.targetCurves.first?.id ?? ""
            }
        }
        correctionStrength = model.currentPreset.correction?.correctionStrength ?? 0.7
        targetBlend = model.currentPreset.correction?.targetBlend ?? 0.85
    }

    private func generate() {
        // Use the picked profile's display name so the engine can fuzzy-match,
        // and forward the goal slug + free-text + safety envelope verbatim.
        let headphoneName = model.headphoneProfiles
            .first { $0.id == headphoneId }?.displayName
        let pref = preference.trimmingCharacters(in: .whitespacesAndNewlines)

        let request = AITuningRequest(
            headphone: headphoneName,
            targetCurveId: targetCurveId.isEmpty ? nil : targetCurveId,
            goalText: nil,
            preference: pref.isEmpty ? nil : pref,
            maxBoostDb: maxBoostDb,
            correctionStrength: correctionStrength,
            targetBlend: targetBlend,
            avoidHarshTreble: avoidHarshTreble
        )
        model.requestTuning(request)
    }
}
