import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AuralinkCore

/// AppKit-backed Import / Export panel helpers for `EQPreset` JSON files.
///
/// The PresetLibraryView hosts the toolbar buttons that drive these; we keep
/// the panel plumbing here so other views (top-bar quick export, drag-and-drop
/// import, etc.) can reuse the same flows.
enum PresetFileIO {
    /// Show an NSOpenPanel for a single `.json` file. Returns the chosen URL
    /// (or nil on cancel).
    @MainActor
    static func importPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Preset"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Show an NSSavePanel pre-filled with a sanitized filename. Returns the
    /// chosen URL (or nil on cancel).
    @MainActor
    static func exportPanel(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Preset"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(safeFileName(suggestedName)).json"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Replace path-illegal characters with `-` so a preset name can be used
    /// as a filename. Returns "preset" if the result would be empty.
    static func safeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "preset" : cleaned
    }
}
