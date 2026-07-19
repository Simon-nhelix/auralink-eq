import SwiftUI
import AppKit

/// Grabs the hosting NSWindow to apply a window level (SwiftUI has no API
/// for always-on-top). Level is re-applied whenever the toggle changes.
///
/// Reusable for any floating SwiftUI window — the Monitor, the editor, etc.
struct WindowLevelAccessor: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        view.window?.level = floating ? .floating : .normal
    }
}
