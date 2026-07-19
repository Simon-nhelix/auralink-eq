import SwiftUI

/// A compact numeric cell: an inline editable text field formatted with the
/// supplied closure plus tiny up/down steppers. Commits the clamped value on
/// Return / focus-loss / stepper tap.
///
/// Reusable for any table cell that needs a small numeric editor — frequency,
/// gain, Q, slope, etc. Accepts "1.2k" / "1.2 khz" shorthand for k-units.
struct NumericField: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let width: CGFloat
    let enabled: Bool
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typo.mono)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                .focused($focused)
                .disabled(!enabled)
                .onSubmit(commitText)
                .onChange(of: focused) { _, isFocused in
                    if isFocused {
                        // Show the raw number while editing for easy entry.
                        text = trimmedNumber(value)
                    } else {
                        commitText()
                    }
                }

            Stepper("",
                    onIncrement: { onCommit(clamp(value + step)) },
                    onDecrement: { onCommit(clamp(value - step)) })
                .labelsHidden()
                .controlSize(.mini)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
        }
        .frame(width: width, alignment: .trailing)
        // Keep the displayed text synced to the model when not actively editing.
        .onChange(of: value) { _, newValue in
            if !focused { text = format(newValue) }
        }
        .onAppear { text = format(value) }
    }

    private func commitText() {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .lowercased()
        // Accept "1.2k" / "1.2 khz" shorthand for frequency entry.
        let multiplier: Double = (cleaned.contains("k")) ? 1_000 : 1
        let numeric = cleaned.filter { "0123456789.+-".contains($0) }
        if let parsed = Double(numeric) {
            onCommit(clamp(parsed * multiplier))
        }
        text = format(clamp(parsedOrCurrent()))
    }

    private func parsedOrCurrent() -> Double {
        let cleaned = text.replacingOccurrences(of: ",", with: "").lowercased()
        let multiplier: Double = cleaned.contains("k") ? 1_000 : 1
        let numeric = cleaned.filter { "0123456789.+-".contains($0) }
        return (Double(numeric).map { $0 * multiplier }) ?? value
    }

    private func clamp(_ v: Double) -> Double {
        Swift.min(Swift.max(v, range.lowerBound), range.upperBound)
    }

    private func trimmedNumber(_ v: Double) -> String {
        // Whole numbers without a decimal, others with up to 2 places.
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }
}
