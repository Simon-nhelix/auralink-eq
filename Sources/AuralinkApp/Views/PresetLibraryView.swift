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
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            header
            searchField
            toolbar
            list
        }
        .padding(Theme.Metrics.pad)
        .background(Theme.Palette.bg)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Gradients.aura)
            Text("Presets")
                .font(Theme.Typo.title)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Text("\(model.presets.count)")
                .font(Theme.Typo.mono)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("Search presets", text: $search)
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

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolButton("New", systemImage: "plus") {
                model.newPreset()
            }
            toolButton("Duplicate", systemImage: "plus.square.on.square") {
                model.duplicate(model.currentPreset)
            }
            toolButton("Rename", systemImage: "pencil") {
                beginRename(model.currentPreset)
            }
            toolButton("Delete", systemImage: "trash", destructive: true) {
                model.delete(model.currentPreset)
            }
            Spacer(minLength: 0)
            toolButton("Import", systemImage: "square.and.arrow.down") {
                importTapped()
            }
            toolButton("Export", systemImage: "square.and.arrow.up") {
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
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                        .fill(Theme.Palette.surfaceHi)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.radiusSm, style: .continuous)
                                .strokeBorder(Theme.Palette.line, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: List (grouped by headphone)

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Metrics.pad, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.key) { group in
                    Section {
                        VStack(spacing: 6) {
                            ForEach(group.presets) { preset in
                                row(preset)
                            }
                        }
                    } header: {
                        HStack {
                            SectionLabel(group.key)
                            Spacer()
                            Text("\(group.presets.count)")
                                .font(Theme.Typo.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .padding(.vertical, 4)
                        .background(Theme.Palette.bg)
                    }
                }
                if groups.isEmpty {
                    Text(search.isEmpty ? "No presets yet." : "No presets match “\(search)”.")
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
            }
        }
    }

    private func row(_ preset: EQPreset) -> some View {
        let isCurrent = preset.id == model.currentPreset.id
        let isRenaming = renamingId == preset.id
        let inCollection = model.collectionPresetIDs.contains(preset.id)
        return AuraCard(padding: 10) {
            HStack(alignment: .center, spacing: Theme.Metrics.gap) {
                VStack(alignment: .leading, spacing: 5) {
                    if isRenaming {
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(Theme.Typo.headline)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .focused($renameFocused)
                            .onSubmit { commitRename(preset) }
                    } else {
                        Text(preset.name)
                            .font(Theme.Typo.headline)
                            .foregroundStyle(isCurrent ? Theme.Palette.accent : Theme.Palette.textPrimary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let hp = preset.headphone, !hp.isEmpty {
                            AuraTag(hp, tint: Theme.Palette.auraBlue)
                        }
                        Text("v\(preset.version)")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        createdByBadge(preset.createdBy)
                        if inCollection {
                            AuraTag("Collection", tint: Theme.Palette.success)
                        }
                    }
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
                    StatusDot(color: Theme.Palette.accent, label: "Loaded", glow: true)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                .strokeBorder(isCurrent ? Theme.Palette.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            model.load(preset: preset)
        }
        .contextMenu {
            Button("Load") { model.load(preset: preset) }
            Button("Rename") { beginRename(preset) }
            Button("Duplicate") { model.duplicate(preset) }
            Button("Export…") { export(preset) }
            Divider()
            if inCollection {
                Button("Remove from My Collection") { model.removeFromCollection(preset) }
            } else {
                Button("Add to My Collection") { model.addToCollection(preset) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(preset) }
        }
    }

    private func createdByBadge(_ by: CreatedBy) -> some View {
        switch by {
        case .ai:
            return AuraTag("AI", tint: Theme.Palette.auraViolet)
        case .user:
            return AuraTag("User", tint: Theme.Palette.textSecondary)
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
            return hp.isEmpty ? "Generic" : hp
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
