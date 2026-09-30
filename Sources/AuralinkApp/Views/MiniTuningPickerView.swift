import AuralinkLocalization
import SwiftUI
import AuralinkCore

/// Searchable headphone/preset chooser shown in place of the Mini Mode's
/// secondary content. Inputs and actions are explicit so the picker remains a
/// presentational desktop component rather than another owner of app state.
struct MiniTuningPickerView: View {
    @Binding var query: String
    @Binding var browseAllHeadphones: Bool

    let profiles: [HeadphoneProfile]
    let presets: [EQPreset]
    let currentProfile: HeadphoneProfile?
    let currentPresetId: String
    /// Fixed ScrollView height. MenuBarExtra collapses unbounded scroll regions;
    /// callers may shrink this when a status notice is also visible so the
    /// popover still fits under the menu bar.
    var listHeight: CGFloat = Theme.Layout.MenuBar.pickerHeight
    let presetsForProfile: (HeadphoneProfile?) -> [EQPreset]
    let onSelectHeadphone: (HeadphoneProfile?) -> Void
    let onSelectPreset: (EQPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField
            resultSummary
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    results
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // MenuBarExtra sizes a ScrollView to almost zero when it only has
            // a maximum height. Reserve real space so search results are
            // visible instead of existing in a collapsed scroll region.
            .frame(height: listHeight)
        }
        .padding(10)
    }

    private var resultSummary: some View {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = trimmedQuery.isEmpty
            ? defaultResultCount
            : matchingHeadphones(query: trimmedQuery).count + matchingPresets(query: trimmedQuery).count

        return HStack(spacing: 6) {
            Text(trimmedQuery.isEmpty ? L10n.text("Available") : L10n.text("Results"))
            Spacer(minLength: 0)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.Palette.textTertiary)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trimmedQuery.isEmpty ? L10n.format("%lld available items", count) : L10n.format("%lld search results", count))
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            MenuBarTextField(
                text: $query,
                placeholder: L10n.text("Search headphones & presets…"),
                autoFocus: true
            )
            .frame(height: 20)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RailFieldBackground())
    }

    @ViewBuilder
    private var results: some View {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            defaultResults
        } else {
            searchResults(for: trimmedQuery)
        }
    }

    @ViewBuilder
    private var defaultResults: some View {
        if browseAllHeadphones {
            sectionLabel(L10n.text("Headphones"))
            pickerRow(
                title: L10n.text("Generic / Flat"),
                subtitle: L10n.text("No headphone correction"),
                icon: currentProfile == nil ? "checkmark.circle.fill" : "circle"
            ) {
                onSelectHeadphone(nil)
            }
            ForEach(profiles) { profile in
                pickerRow(
                    title: profile.displayName,
                    subtitle: L10n.format("%lld presets", presetsForProfile(profile).count),
                    icon: currentProfile?.id == profile.id ? "checkmark.circle.fill" : "headphones"
                ) {
                    onSelectHeadphone(profile)
                }
            }
        } else {
            sectionLabel(currentProfile?.displayName ?? L10n.text("Generic presets"))
            let scopedPresets = presetsForProfile(currentProfile)
            if scopedPresets.isEmpty {
                Text(L10n.text("No saved presets for this headphone."))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.vertical, 5)
            } else {
                ForEach(scopedPresets.prefix(5)) { preset in
                    presetRow(preset)
                }
            }
            Button {
                browseAllHeadphones = true
            } label: {
                Label(L10n.text("Browse headphones"), systemImage: "headphones")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func searchResults(for text: String) -> some View {
        let matchedProfiles = matchingHeadphones(query: text)
        let matchedPresets = matchingPresets(query: text)
        if matchedProfiles.isEmpty && matchedPresets.isEmpty {
            Text(L10n.format("No headphones or presets match “%@”.", String(text)))
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.vertical, 6)
        } else {
            if !matchedProfiles.isEmpty {
                sectionLabel(L10n.text("Headphones"))
                ForEach(matchedProfiles) { profile in
                    pickerRow(
                        title: profile.displayName,
                        subtitle: L10n.format("%lld presets", presetsForProfile(profile).count),
                        icon: "headphones"
                    ) {
                        onSelectHeadphone(profile)
                    }
                }
            }
            if !matchedPresets.isEmpty {
                sectionLabel(L10n.text("Presets"))
                ForEach(matchedPresets) { preset in
                    presetRow(preset)
                }
            }
        }
    }

    private func presetRow(_ preset: EQPreset) -> some View {
        pickerRow(
            title: preset.name,
            subtitle: L10n.format("%lld bands · %@", preset.activeBands.count, String(preset.createdBy == .ai ? L10n.text("AI") : L10n.text("User"))),
            icon: preset.id == currentPresetId ? "checkmark.circle.fill" : "slider.horizontal.3"
        ) {
            onSelectPreset(preset)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(Theme.Palette.textTertiary)
            .lineLimit(1)
            .padding(.top, 2)
    }

    private func pickerRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(icon == "checkmark.circle.fill" ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortTitle(title))
                        .font(Theme.Typo.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Palette.raised)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    private func matchingHeadphones(query: String) -> [HeadphoneProfile] {
        let needle = normalized(query)
        return Array(profiles
            .filter { normalized($0.displayName).contains(needle) }
            .prefix(5))
    }

    private func matchingPresets(query: String) -> [EQPreset] {
        let needle = normalized(query)
        return Array(presets.filter { preset in
            normalized(preset.name).contains(needle)
                || normalized(preset.headphone ?? "").contains(needle)
                || normalized(preset.goal ?? "").contains(needle)
                || preset.tags.contains { normalized($0).contains(needle) }
        }.prefix(6))
    }

    private var defaultResultCount: Int {
        if browseAllHeadphones {
            return profiles.count + 1
        }
        return presetsForProfile(currentProfile).count + 1
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func shortTitle(_ title: String) -> String {
        guard title.count > 42 else { return title }
        return "\(title.prefix(20))…\(title.suffix(18))"
    }
}
