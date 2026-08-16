import SwiftUI
import AuralinkCore

/// The AI proposal review overlay (plan §8.1).
///
/// When `model.pendingProposal` is set, the editor overlays this card on a
/// dimmed backdrop. It summarizes *what the AI wants to do* — intent bullets,
/// the per-band change list, the resulting preamp, and a validation/clipping
/// verdict — then offers the explicit write actions. Nothing is applied until
/// the user chooses, which is the whole point of the confirm step.
struct AIResultView: View {
    @EnvironmentObject var model: AppModel
    /// Called when the user picks "Edit Manually" — the host (EditorWindow)
    /// dismisses the overlay into the band editor.
    var onEditManually: () -> Void = {}

    var body: some View {
        // Defensive: if the proposal vanished, render nothing rather than crash.
        if let result = model.pendingProposal {
            card(for: result)
                .frame(maxWidth: 540)
                .padding(Theme.Metrics.pad)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    // MARK: Card

    private func card(for result: TuningResult) -> some View {
        AuraCard(padding: Theme.Metrics.pad) {
            VStack(alignment: .leading, spacing: Theme.Metrics.pad) {
                header(for: result)
                Divider().overlay(Theme.Palette.line)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metrics.pad) {
                        intentSection(result.intent)
                        changesSection(result.changes)
                        if !result.basis.isEmpty {
                            basisSection(result.basis)
                        }
                    }
                }
                .frame(maxHeight: 320)

                Divider().overlay(Theme.Palette.line)
                footerMeta(for: result)
                actions
            }
        }
    }

    // MARK: Header (name + validation badge)

    private func header(for result: TuningResult) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.gap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Gradients.aura)
                    Text("Proposed Tuning")
                        .font(Theme.Typo.caption)
                        .tracking(0.8)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Text(result.preset.name)
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                if let hp = result.preset.headphone, !hp.isEmpty {
                    AuraTag(hp, tint: Theme.Palette.auraBlue)
                }
            }
            Spacer(minLength: 0)
            validationBadge(result.validation)
        }
    }

    private func validationBadge(_ v: ValidationResult) -> some View {
        let tint = ValidationFormatting.riskTint(v.clippingRisk)
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: v.ok ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(v.ok ? "Validated" : "Has errors")
                    .font(Theme.Typo.label)
            }
            .foregroundStyle(v.ok ? Theme.Palette.success : Theme.Palette.danger)

            StatusDot(color: tint,
                      label: "Clipping: \(v.clippingRisk.displayName)",
                      glow: v.clippingRisk == .high)
        }
    }

    // MARK: Intent

    private func intentSection(_ intent: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Intent")
            if intent.isEmpty {
                Text("No stated intent.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                ForEach(Array(intent.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Theme.Palette.accent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(line)
                            .font(Theme.Typo.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Changes

    private func changesSection(_ changes: [TuningChange]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Changes")
            if changes.isEmpty {
                Text("No band changes vs the current preset.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(changes) { change in
                        HStack(alignment: .top, spacing: Theme.Metrics.gap) {
                            Text("B\(change.bandIndex)")
                                .font(Theme.Typo.mono)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.summary)
                                    .font(Theme.Typo.mono)
                                    .foregroundStyle(Theme.Palette.accent)
                                Text(change.rationale)
                                    .font(Theme.Typo.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func basisSection(_ basis: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Basis")
            Text(basis)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer meta + validation issues

    private func footerMeta(for result: TuningResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.Metrics.pad) {
                metaItem(label: "Preamp", value: Fmt.db(result.preset.preampDb))
                metaItem(label: "Peak gain", value: Fmt.db(result.validation.estimatedPeakGainDb))
                metaItem(label: "Bands", value: "\(result.preset.activeBands.count) active")
                Spacer(minLength: 0)
            }

            if let correction = result.preset.correction {
                HStack(spacing: Theme.Metrics.pad) {
                    metaItem(label: "Role", value: PresetFormatting.roleLabel(correction.role))
                    metaItem(label: "Correction", value: PresetFormatting.percent(correction.correctionStrength))
                    metaItem(label: "Target", value: PresetFormatting.percent(correction.targetBlend))
                    Spacer(minLength: 0)
                }
            }

            if !result.validation.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(result.validation.issues.enumerated()), id: \.offset) { _, issue in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: ValidationFormatting.issueIcon(issue.severity))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(ValidationFormatting.issueTint(issue.severity))
                            Text(issue.message)
                                .font(Theme.Typo.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func metaItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Typo.caption)
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: Theme.Metrics.gap) {
            HStack(spacing: Theme.Metrics.gap) {
                Button {
                    model.applyProposal()
                } label: {
                    Label("Apply", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: true))

                Button {
                    model.saveProposalAsDraft()
                } label: {
                    Label("Save Draft", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: false))
            }

            HStack(spacing: Theme.Metrics.gap) {
                Button {
                    if let proposal = model.pendingProposal {
                        model.auditionTransientPreset(
                            proposal.preset,
                            message: "Comparing the proposal against the previous preset."
                        )
                    }
                    model.toggleAB()
                } label: {
                    Label(model.comparingBefore ? "A/B: Before" : "Compare A/B",
                          systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: false))

                Button {
                    onEditManually()
                } label: {
                    Label("Edit Manually", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: false))

                Button(role: .destructive) {
                    model.discardProposal()
                } label: {
                    Label("Discard", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: false))
            }
        }
    }

    // MARK: Styling helpers

    private func riskTint(_ risk: ClippingRisk) -> Color {
        switch risk {
        case .low:    return Theme.Palette.success
        case .medium: return Theme.Palette.warning
        case .high:   return Theme.Palette.danger
        }
    }

    private func issueIcon(_ severity: ValidationSeverity) -> String {
        switch severity {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private func issueTint(_ severity: ValidationSeverity) -> Color {
        switch severity {
        case .info:    return Theme.Palette.textSecondary
        case .warning: return Theme.Palette.warning
        case .error:   return Theme.Palette.danger
        }
    }

    // MARK: - Style helpers (validation formatters moved to ValidationFormatting,
    // role/percent formatters moved to PresetFormatting)

    // (Local copies of riskTint / issueIcon / issueTint removed; use
    // ValidationFormatting.* directly.)
}
