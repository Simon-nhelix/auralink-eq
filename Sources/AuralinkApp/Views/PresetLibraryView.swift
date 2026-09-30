import AuralinkLocalization
import SwiftUI
import AuralinkCore
import UniformTypeIdentifiers
import AppKit

/// Right-side "Presets" panel — the saved preset library.
///
/// A searchable, headphone-grouped list of `model.presets`. Each row shows the
/// name, a headphone `AuraTag`, the version, and an AI/user badge. Tapping loads
/// the preset into the editor (`model.load`). The toolbar covers the full
/// lifecycle — New, Duplicate, Delete, Import, Export, and inline Rename.
struct PresetLibraryView: View {
    @EnvironmentObject var model: AppModel

    @State private var search: String = ""
    /// The preset whose name is currently being edited inline (by id).
    @State private var renamingId: String? = nil
    @State private var renameText: String = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            list
        }
        .padding(.horizontal, Theme.Metrics.padLg)
        .padding(.top, 2)
    }

    // MARK: Header (title + tools)

    private var header: some View {
        HStack(spacing: 2) {
            RailPanelTitle(L10n.text("Presets"))
            Text("\(model.presets.count)")
                .font(Theme.Typo.mono.weight(.regular))
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.leading, 6)
            Spacer(minLength: 8)
            toolButton(L10n.text("New"), systemImage: "plus") {
                model.newPreset()
            }
            toolButton(L10n.text("Duplicate"), systemImage: "plus.square.on.square") {
                model.duplicate(model.currentPreset)
            }
            toolButton(L10n.text("Rename"), systemImage: "pencil") {
                beginRename(model.currentPreset)
            }
            toolButton(L10n.text("Delete"), systemImage: "trash", destructive: true) {
                model.delete(model.currentPreset)
            }
            Rectangle()
                .fill(Theme.Palette.line)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 4)
            toolButton(L10n.text("Import"), systemImage: "square.and.arrow.down") {
                importTapped()
            }
            toolButton(L10n.text("Export"), systemImage: "square.and.arrow.up") {
                exportTapped()
            }
        }
    }

    private func toolButton(_ label: String, systemImage: String,
                            destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive ? Theme.Palette.danger : Theme.Palette.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField(L10n.text("Search presets"), text: $search)
                .textFieldStyle(.plain)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RailFieldBackground())
    }

    // MARK: List (grouped by headphone)

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.key) { group in
                    Section {
                        VStack(spacing: 2) {
                            ForEach(group.presets) { preset in
                                row(preset)
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            SectionLabel(group.key)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(group.presets.count)")
                                .font(Theme.Typo.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 6)
                        .background(Theme.Palette.surface)
                    }
                }
                if groups.isEmpty {
                    Text(search.isEmpty ? L10n.text("No presets yet.") : L10n.format("No presets match “%@”.", String(search)))
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
            }
            .padding(.bottom, Theme.Metrics.padLg)
        }
    }

    private func row(_ preset: EQPreset) -> some View {
        let isCurrent = preset.id == model.currentPreset.id
        let isRenaming = renamingId == preset.id
        let inCollection = model.collectionPresetIDs.contains(preset.id)
        return PresetRowContainer(selected: isCurrent) {
            HStack(alignment: .center, spacing: Theme.Metrics.gap) {
                VStack(alignment: .leading, spacing: 3) {
                    if isRenaming {
                        TextField(L10n.text("Name"), text: $renameText)
                            .textFieldStyle(.plain)
                            .font(Theme.Typo.body.weight(.medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .focused($renameFocused)
                            .onSubmit { commitRename(preset) }
                    } else {
                        Text(preset.name)
                            .font(Theme.Typo.body.weight(.medium))
                            .foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(metaLine(preset, inCollection: inCollection))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isRenaming {
                    Button {
                        commitRename(preset)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Palette.success)
                    }
                    .buttonStyle(.plain)
                } else if isCurrent {
                    StatusDot(color: Theme.Palette.accent, label: L10n.text("Loaded"))
                }
            }
        }
        .onTapGesture {
            guard !isRenaming else { return }
            model.load(preset: preset)
        }
        .contextMenu {
            Button(L10n.text("Load")) { model.load(preset: preset) }
            Button(L10n.text("Rename")) { beginRename(preset) }
            Button(L10n.text("Duplicate")) { model.duplicate(preset) }
            Button(L10n.text("Export…")) { export(preset) }
            Divider()
            if inCollection {
                Button(L10n.text("Remove from My Collection")) { model.removeFromCollection(preset) }
            } else {
                Button(L10n.text("Add to My Collection")) { model.addToCollection(preset) }
            }
            Divider()
            Button(L10n.text("Delete"), role: .destructive) { model.delete(preset) }
        }
    }

    /// "v3 · AI · Collection" — version, author, and collection membership.
    private func metaLine(_ preset: EQPreset, inCollection: Bool) -> String {
        var parts = ["v\(preset.version)", createdByLabel(preset.createdBy)]
        if inCollection { parts.append(L10n.text("Collection")) }
        return parts.joined(separator: " · ")
    }

    private func createdByLabel(_ by: CreatedBy) -> String {
        switch by {
        case .ai: return L10n.text("AI")
        case .user: return L10n.text("User")
        }
    }

    // MARK: Grouping / filtering

    private struct PresetGroup { let key: String; let presets: [EQPreset] }

    private var filtered: [EQPreset] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return model.presets }
        return model.presets.filter { p in
            p.name.lowercased().contains(q)
                || (p.headphone?.lowercased().contains(q) ?? false)
                || (p.goal?.lowercased().contains(q) ?? false)
                || p.tags.contains { $0.lowercased().contains(q) }
        }
    }

    private var groups: [PresetGroup] {
        let buckets = Dictionary(grouping: filtered) { p -> String in
            let hp = p.headphone?.trimmingCharacters(in: .whitespaces) ?? ""
            return hp.isEmpty ? L10n.text("Generic") : hp
        }
        return buckets
            .map { PresetGroup(key: $0.key, presets: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    // MARK: Rename

    private func beginRename(_ preset: EQPreset) {
        renamingId = preset.id
        renameText = preset.name
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ preset: EQPreset) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != preset.name {
            model.rename(preset, to: name)
        }
        renamingId = nil
        renameFocused = false
    }

    // MARK: Import / Export (panels live in PresetFileIO)

    private func importTapped() {
        if let url = PresetFileIO.importPanel() {
            model.importPreset(from: url)
        }
    }

    private func exportTapped() {
        export(model.currentPreset)
    }

    private func export(_ preset: EQPreset) {
        if let url = PresetFileIO.exportPanel(suggestedName: preset.name) {
            model.exportPreset(preset, to: url)
        }
    }
}

/// Flat preset row: accent-tinted when loaded, a faint highlight on hover.
/// Not a Button, so the inline rename field inside it stays editable.
private struct PresetRowContainer<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                    .fill(selected ? Theme.Palette.accentSoft : (hovering ? Theme.Palette.lineSoft : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
