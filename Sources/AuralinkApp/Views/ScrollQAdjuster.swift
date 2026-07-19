import SwiftUI
import AppKit

/// Transparent AppKit overlay that captures scroll-wheel deltas (for Q/slope
/// editing) without interfering with SwiftUI clicks/drags. Place it in a
/// ZStack *below* the interactive layer, so child gestures still win the
/// hit-test.
struct ScrollQAdjuster: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCatchView {
        let v = ScrollCatchView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: ScrollCatchView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollCatchView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            // scrollingDeltaY is positive when scrolling up on most devices.
            onScroll?(event.scrollingDeltaY)
        }
    }
}
