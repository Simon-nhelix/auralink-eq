import SwiftUI
import AppKit

/// A narrow AppKit bridge for editable text inside `MenuBarExtra(.window)`.
/// SwiftUI continues to own the string; AppKit only supplies reliable first-
/// responder and text-system behavior for the system popover.
struct MenuBarTextField: NSViewRepresentable {
    @Binding var text: String

    let placeholder: String
    var autoFocus = false
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        field.textColor = NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.68, alpha: 1),
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]
        )
        field.stringValue = text
        field.shouldFocusWhenAttached = autoFocus
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: FocusableTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        field.shouldFocusWhenAttached = autoFocus
        if field.stringValue != text {
            field.stringValue = text
        }
        if autoFocus {
            field.requestInitialFocusIfNeeded()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }
    }
}

final class FocusableTextField: NSTextField {
    var shouldFocusWhenAttached = false
    private var didRequestInitialFocus = false

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestInitialFocusIfNeeded()
    }

    func requestInitialFocusIfNeeded() {
        guard shouldFocusWhenAttached, !didRequestInitialFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didRequestInitialFocus, let window = self.window else { return }
            self.didRequestInitialFocus = true
            window.makeFirstResponder(self)
            self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0)
        }
    }
}
