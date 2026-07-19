import AppKit

extension AppModel {
    func uiChanged() {
        if uiPublishesSuppressed {
            uiPublishFlushPending = true
        } else {
            objectWillChange.send()
        }
    }

    /// Recomputes whether anyone can currently see the UI and opens/closes the
    /// invalidation gate. "Engaged" means: the app is active, or some window is
    /// key (the menubar popover is a borderless key panel), or a titled window
    /// (editor / Monitor) is actually visible on screen — a floating Monitor
    /// parked in a corner keeps live-updating; a fully occluded, minimized, or
    /// closed one does not. Called on app activation changes and on window
    /// key/occlusion/close notifications (AppDelegate observers).
    func reevaluateUIPublishGate() {
        let engaged = NSApp.isActive
            || NSApp.keyWindow != nil
            || NSApp.windows.contains { window in
                window.styleMask.contains(.titled)
                    && window.isVisible
                    && window.occlusionState.contains(.visible)
            }
        let suppressed = !engaged
        guard suppressed != uiPublishesSuppressed else { return }
        uiPublishesSuppressed = suppressed
        if !suppressed && uiPublishFlushPending {
            uiPublishFlushPending = false
            objectWillChange.send()
        }
    }
}
