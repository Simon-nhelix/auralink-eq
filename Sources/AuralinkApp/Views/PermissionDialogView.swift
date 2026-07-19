import SwiftUI
import AuralinkCore

/// Confirmation surface for an AI-proposed write action (plan §8.1).
///
/// This is the "ask before write" gate: when the connected AI/MCP client wants
/// to create or apply a tuning, this view summarizes *exactly* what it intends
/// to do — the resulting preset name, its stated intents, the concrete per-band
/// changes (with rationale), and a validation/clipping verdict — and gives the
/// user the full set of safe responses.
///
/// It is intentionally self-contained (no `@EnvironmentObject`): callers inject
/// the `TuningResult` and the action closures, so the same view works for the
/// in-app AI flow, the editor overlay, and a future system confirmation prompt.
struct PermissionDialogView: View {
    let result: TuningResult
    let onApply: () -> Void
    let onSaveDraft: () -> Void
    let onCompare: () -> Void
    let onEdit: () -> Void
    let onDiscard: () -> Void

    init(
        result: TuningResult,
        onApply: @escaping () -> Void,
        onSaveDraft: @escaping () -> Void,
        onCompare: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.result = result
        self.onApply = onApply
        self.onSaveDraft = onSaveDraft
        self.onCompare = onCompare
        self.onEdit = onEdit
        self.onDiscard = onDiscard
    }

    private var preset: EQPreset { result.preset }
    private var validation: ValidationResult { result.validation }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            header
            Divider().overlay(Theme.Palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.pad) {
                    if !result.intent.isEmpty { intentSection }
                    if !result.changes.isEmpty { changesSection }
                    if !validation.issues.isEmpty { issuesSection }
                    if !result.basis.isEmpty { basisSection }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 320)

            Divider().overlay(Theme.Palette.line)
            actionButtons
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 420)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radiusLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radiusLg, style: .continuous)
                .strokeBorder(Theme.Palette.line, lineWidth: 1)
        )
    }

    // MARK: Header (title + badges)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.Palette.auraViolet)
                Text("AI Tuning Proposal")
                    .font(Theme.Typo.caption)
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                clippingBadge
            }
            HStack(spacing: 8) {
                Text(preset.name)
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                if let hp = preset.headphone, !hp.isEmpty {
                    AuraTag(hp, tint: Theme.Palette.auraBlue)
                }
            }
            if let goal = preset.goal, !goal.isEmpty {
                Text(goal)
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Green/yellow/red clipping verdict driven by `ClippingRisk`.
    private var clippingBadge: some View {
        let color = clippingColor
        let label = "\(validation.clippingRisk.displayName) clip risk"
        return HStack(spacing: 6) {
            Image(systemName: validation.ok ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                .font(.system(size: 11))
            Text(validation.ok ? label : "Validation failed")
                .font(Theme.Typo.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            Capsule().fill(color.opacity(0.14))
                .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 1))
        )
    }

    private var clippingColor: Color {
        if !validation.ok { return Theme.Palette.danger }
        switch validation.clippingRisk {
        case .low:    return Theme.Palette.success
        case .medium: return Theme.Palette.warning
        case .high:   return Theme.Palette.danger
        }
    }

    // MARK: Intent bullets

    private var intentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Intent")
            ForEach(Array(result.intent.enumerated()), id: \.offset) { _, line in
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

    // MARK: Per-band changes

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Changes")
            VStack(spacing: 6) {
                ForEach(result.changes) { change in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(change.bandIndex)")
                            .font(Theme.Typo.mono)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(width: 20, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.summary)
                                .font(Theme.Typo.mono)
                                .foregroundStyle(Theme.Palette.auraCyan)
                            if !change.rationale.isEmpty {
                                Text(change.rationale)
                                    .font(Theme.Typo.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                            .fill(Theme.Palette.surfaceHi)
                    )
                }
            }
        }
    }

    // MARK: Validation issues

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Validation")
            ForEach(Array(validation.issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ValidationFormatting.issueIcon(issue.severity))
                        .font(.system(size: 11))
                        .foregroundStyle(issueColor(issue.severity))
                        .padding(.top, 1)
                    Text(issue.message)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 14) {
                Text("Peak \(Fmt.db(validation.estimatedPeakGainDb))")
                Text("Auto-preamp \(Fmt.db(validation.suggestedPreampDb))")
            }
            .font(Theme.Typo.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.top, 2)
        }
    }

    private func issueColor(_ s: ValidationSeverity) -> Color {
        switch s {
        case .info:    return Theme.Palette.accent
        case .warning: return Theme.Palette.warning
        case .error:   return Theme.Palette.danger
        }
    }

    // MARK: Basis / attribution

    private var basisSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Basis")
            Text(result.basis)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private var actionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onApply) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text("Apply")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle())
                .disabled(!validation.ok)

                Button(action: onSaveDraft) {
                    Text("Save Draft").frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: false))
            }
            HStack(spacing: 8) {
                Button(action: onCompare) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                        Text("Compare A/B")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: false))

                Button(action: onEdit) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Edit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: false))

                Button(action: onDiscard) {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                .buttonStyle(AuraButtonStyle(prominent: false))
            }
        }
    }
}
