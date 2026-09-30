/// Hardware-free watchdog decisions for the app's ~100 ms telemetry windows.
/// Background callback stalls are tolerated; binding and feedback protection
/// stay active regardless of application focus.
public struct AudioRoutingWatchdog: Sendable {
    public struct Actions: Equatable, Sendable {
        public var checkOutputBinding = false
        public var stopFeedback = false
        public var recoverStall = false
        public var resetRecoveryAttempts = false
    }

    private var bindingTicks = 0
    private var feedbackTicks = 0
    private var stalledTicks = 0
    private var healthyTicks = 0

    public init() {}

    public mutating func reset() {
        self = AudioRoutingWatchdog()
    }

    public mutating func update(
        routingRequested: Bool,
        isBackgrounded: Bool,
        running: Bool,
        systemOutputRoutedToAuralink: Bool,
        clipping: Bool,
        capturePeakDb: Double,
        renderCallbacks: Int,
        captureCallbacks: Int,
        recoveryPending: Bool = false
    ) -> Actions {
        guard routingRequested else {
            reset()
            return Actions()
        }
        var actions = Actions()

        if running {
            bindingTicks += 1
            if bindingTicks >= 10 {
                bindingTicks = 0
                actions.checkOutputBinding = true
            }
        }

        if running && systemOutputRoutedToAuralink && clipping && capturePeakDb >= -0.02 {
            feedbackTicks += 1
            if feedbackTicks >= 50 {
                feedbackTicks = 0
                actions.stopFeedback = true
                return actions
            }
        } else {
            feedbackTicks = 0
        }

        // Only cadence-based stall detection is suppressed in the background.
        // A definite hard stop still needs recovery, and protection above must
        // run even when the engine reports itself healthy.
        if isBackgrounded && running {
            stalledTicks = 0
            healthyTicks = 0
            return actions
        }

        let stalled = !running || renderCallbacks == 0
            || (systemOutputRoutedToAuralink && captureCallbacks == 0)
        if stalled {
            healthyTicks = 0
            stalledTicks += 1
            if stalledTicks >= 30 && !recoveryPending {
                stalledTicks = 0
                actions.recoverStall = true
            }
        } else {
            stalledTicks = 0
            healthyTicks += 1
            if healthyTicks >= 100 {
                healthyTicks = 0
                actions.resetRecoveryAttempts = true
            }
        }
        return actions
    }
}
