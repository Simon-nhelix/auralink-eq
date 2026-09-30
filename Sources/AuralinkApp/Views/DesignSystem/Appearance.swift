import AppKit
import AuralinkLocalization
import SwiftUI

/// The user's appearance choice. `system` follows macOS; `light` and `dark`
/// pin every Auralink window, the menu bar popover included, to one appearance.
/// Palette colors resolve per appearance, so switching needs no view changes.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "AuralinkAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.text("System")
        case .light: return L10n.text("Light")
        case .dark: return L10n.text("Dark")
        }
    }

    /// `nil` lets windows inherit the system appearance.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var stored: AppearancePreference {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    @MainActor
    func apply() {
        NSApp.appearance = appearance
    }
}

/// System / Light / Dark picker. Inside a `Menu` or the main menu it renders
/// as a submenu with a checkmark on the current choice.
struct AppearancePicker: View {
    @AppStorage(AppearancePreference.defaultsKey) private var preference: AppearancePreference = .system

    var body: some View {
        Picker(
            L10n.text("Appearance"),
            selection: Binding(
                get: { preference },
                set: { value in
                    // Apply here rather than in onChange: menu content is not
                    // guaranteed to stay alive after the menu closes.
                    preference = value
                    value.apply()
                }
            )
        ) {
            ForEach(AppearancePreference.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }
}

/// Adds the appearance picker to the View menu.
struct AppearanceCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            AppearancePicker()
        }
    }
}
