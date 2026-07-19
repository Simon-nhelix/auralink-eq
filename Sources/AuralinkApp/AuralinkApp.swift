import SwiftUI
import AppKit
import AuralinkCore

/// Auralink EQ — the @main entry point.
///
/// The app exposes a menubar control surface plus a full editor window. A single
/// `AppModel` is created and owned by the `AppDelegate` so the MCP/control API is
/// live as soon as the process starts. The audio engine itself stays stopped
/// until the user or an MCP client explicitly starts routing.
@main
struct AuralinkApp: App {

    /// Owns the model and runs launch side effects in applicationDidFinishLaunching.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // MARK: Menubar surface (the app's "home").
        MenuBarExtra("Auralink", systemImage: "waveform") {
            MenuBarView()
                .environmentObject(delegate.model)
        }
        .menuBarExtraStyle(.window)

        // MARK: Full editor, visible on launch for the testable desktop build.
        WindowGroup("Auralink EQ", id: "editor") {
            EditorWindow()
                .environmentObject(delegate.model)
                .frame(minWidth: Theme.Metrics.editorMinWidth,
                       minHeight: Theme.Metrics.editorMinHeight)
        }
        .windowResizability(.contentMinSize)

        // MARK: Standalone live path monitor — small, floatable, made to sit
        // in a corner during long listening sessions.
        Window("Auralink Monitor", id: "monitor") {
            MonitorWindowView()
                .environmentObject(delegate.model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 540, height: 460)
    }
}

/// Owns the app's lifetime objects and bootstraps them at launch.
///
/// Using an `NSApplicationDelegate` is what guarantees the model, the audio
/// routing engine, and the localhost control server are all live the moment the
/// app starts — a `MenuBarExtra`'s content view only `onAppear`s when the user
/// opens the popover, which would otherwise leave the MCP server unable to reach
/// the app until the menubar was clicked.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The one source of truth, owned for the app's lifetime. Created on the main
    /// thread when the delegate is instantiated (before any scene renders).
    let model: AppModel = MainActor.assumeIsolated { AppModel() }

    /// The loopback HTTP API for the MCP server, held so it lives with the app.
    private var controlServer: ControlServer?
    private var willSleepObserver: Any?
    private var didWakeObserver: Any?
    private var didBecomeActiveObserver: Any?
    private var didResignActiveObserver: Any?
    private var windowGateObservers: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)

            // Stand up the loopback HTTP API the MCP server talks to.
            let server = ControlServer(model: model)
            if server.start() {
                controlServer = server
                model.setControlServerRunning(true)
            } else {
                model.setControlServerRunning(false)
                model.lastError = "The local control server could not start securely."
            }

            // Wire up domain + device state. Live audio routing starts only after
            // an explicit user/MCP action so launching the app never steals sound.
            model.bootstrap()
            installPowerObservers()
            installActivationObservers()
            installWindowGateObservers()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.stopSystemEQ()
            model.restoreDanglingSystemOutputIfNeeded()
            controlServer?.stop()
            model.setControlServerRunning(false)
        }
        removePowerObservers()
        removeActivationObservers()
        removeWindowGateObservers()
    }

    // MARK: - App activation observers (background → foreground)

    /// macOS delivers `didBecomeActiveNotification` for ordinary app switches
    /// (⌘Tab, clicking another window, then returning) — events the sleep/wake
    /// observers never see, but which can still leave the audio path stale
    /// (CoreAudio reconfigures devices freely while we're in the background).
    private func installActivationObservers() {
        removeActivationObservers()
        let center = NotificationCenter.default
        didBecomeActiveObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.handleAppBecameActive()
            }
        }
        didResignActiveObserver = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.handleAppResignedActive()
            }
        }
    }

    private func removeActivationObservers() {
        let center = NotificationCenter.default
        if let didBecomeActiveObserver {
            center.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
        if let didResignActiveObserver {
            center.removeObserver(didResignActiveObserver)
            self.didResignActiveObserver = nil
        }
    }

    // MARK: - Window observers (UI publish gate)

    /// Window key/visibility transitions feed `AppModel.reevaluateUIPublishGate()`
    /// — the switch that withholds SwiftUI invalidations while nobody can see
    /// the UI (the macOS 26 DesignLibrary background-layout crash mitigation).
    /// App activation alone isn't enough: the menubar popover opening, the
    /// Monitor window being covered/uncovered by other apps' windows, or a
    /// window closing all change UI visibility without an activation event.
    private func installWindowGateObservers() {
        removeWindowGateObservers()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification
        ]
        for name in names {
            windowGateObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Defer one turn: key/visibility state settles after the
                // notification (e.g. resign-key fires before the next window
                // becomes key, will-close before isVisible flips).
                Task { @MainActor in
                    self?.model.reevaluateUIPublishGate()
                }
            })
        }
    }

    private func removeWindowGateObservers() {
        let center = NotificationCenter.default
        for observer in windowGateObservers {
            center.removeObserver(observer)
        }
        windowGateObservers.removeAll()
    }

    private func installPowerObservers() {
        removePowerObservers()
        let center = NSWorkspace.shared.notificationCenter
        willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.prepareForSystemSleep()
            }
        }
        didWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.recoverFromSystemWake()
            }
        }
    }

    private func removePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let willSleepObserver {
            center.removeObserver(willSleepObserver)
            self.willSleepObserver = nil
        }
        if let didWakeObserver {
            center.removeObserver(didWakeObserver)
            self.didWakeObserver = nil
        }
    }
}
