import SwiftUI

/// Simple wrapping tag row used for harsh regions and similar short labels.
/// Lays tags left-to-right and wraps to a new line when the width runs out.
struct FlowTags: View {
    let items: [String]
    var tint: Color = Theme.Palette.accent

    var body: some View {
        // A lightweight wrap using a measured layout. For the small counts here
        // (a handful of regions) this is plenty efficient.
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                AuraTag(item, tint: tint)
            }
        }
    }
}

/// Minimal flow layout (left-to-right, wrapping) for tag pills and any other
/// short-label row. Pure SwiftUI `Layout` protocol — no model dependency.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
