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
            VStack(alignment: .leading, spacing: 18) {
                headphoneSection
                goalSection
                RailDivider()
                strengthSection
                preferenceSection
                RailDivider()
                safetySection
                VStack(spacing: 10) {
                    generateButton
                    quickActions
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, Theme.Metrics.padLg)
            .padding(.top, 2)
            .padding(.bottom, Theme.Metrics.padLg)
        }
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
        VStack(alignment: .leading, spacing: 7) {
            RailSectionTitle(L10n.text("Headphone"))
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
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                RailSectionTitle(L10n.text("Goal"))
                Spacer(minLength: 0)
                if let curve = selectedCurve {
                    AuraTag(L10n.text(curve.category.displayName))
                }
            }
            Picker(L10n.text("Goal"), selection: $targetCurveId) {
                ForEach(model.targetCurves) { curve in
                    Text(curve.name).tag(curve.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.Palette.accent)

            if let curve = selectedCurve {
                Text(curve.description)
                    .font(Theme.Typo.label.weight(.regular))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Strength

    private var strengthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RailSectionTitle(L10n.text("Strength"))
            strengthRow(L10n.text("Correction"), value: $correctionStrength, tint: Theme.Palette.accent)
            strengthRow(L10n.text("Target blend"), value: $targetBlend, tint: Theme.Palette.accent)
        }
    }

    private func strengthRow(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.Typo.label.weight(.regular))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 88, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05)
                .controlSize(.small)
                .tint(tint)
            Text(PresetFormatting.percent(value.wrappedValue))
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: Preference

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            RailSectionTitle(L10n.text("Preference"))
            TextField(L10n.text("e.g. keep vocals, brighter guitars, a bit more kick"),
                      text: $preference, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2...3)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RailFieldBackground())
        }
    }

    // MARK: Safety

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            RailSectionTitle(L10n.text("Safety"))

            HStack(spacing: 8) {
                Text(L10n.text("Max boost"))
                    .font(Theme.Typo.label.weight(.regular))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(Fmt.db(maxBoostDb))
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Stepper(L10n.text("Max boost"), value: $maxBoostDb, in: 0...18, step: 0.5)
                    .labelsHidden()
                    .controlSize(.small)
            }

            Toggle(isOn: $avoidHarshTreble) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Avoid harsh treble"))
                        .font(Theme.Typo.label.weight(.regular))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(L10n.text("Prefer cuts over boosts in the 5–9 kHz fatigue region."))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
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
                    Image(systemName: "sparkles")
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
            HStack(spacing: 16) {
                Spacer(minLength: 0)
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
            .font(Theme.Typo.label)
            .disabled(model.isTuning)
            .opacity(model.isTuning ? 0.5 : 1)
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
