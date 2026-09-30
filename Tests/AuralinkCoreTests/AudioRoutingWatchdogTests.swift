import XCTest
@testable import AuralinkCore

final class AudioRoutingWatchdogTests: XCTestCase {
    private func tick(
        _ watchdog: inout AudioRoutingWatchdog,
        backgrounded: Bool = false,
        running: Bool = true,
        routed: Bool = true,
        clipping: Bool = false,
        capturePeakDb: Double = -12,
        renderCallbacks: Int = 10,
        captureCallbacks: Int = 10,
        requested: Bool = true,
        recoveryPending: Bool = false
    ) -> AudioRoutingWatchdog.Actions {
        watchdog.update(
            routingRequested: requested,
            isBackgrounded: backgrounded,
            running: running,
            systemOutputRoutedToAuralink: routed,
            clipping: clipping,
            capturePeakDb: capturePeakDb,
            renderCallbacks: renderCallbacks,
            captureCallbacks: captureCallbacks,
            recoveryPending: recoveryPending
        )
    }

    func testBackgroundFeedbackStillStopsAndChecksBinding() {
        var watchdog = AudioRoutingWatchdog()
        var bindingChecks = 0
        for window in 1...50 {
            let actions = tick(&watchdog, backgrounded: true, clipping: true, capturePeakDb: 0)
            if actions.checkOutputBinding { bindingChecks += 1 }
            XCTAssertEqual(actions.stopFeedback, window == 50)
            XCTAssertFalse(actions.recoverStall)
        }
        XCTAssertEqual(bindingChecks, 5)
    }

    func testBackgroundCallbackGapsDoNotRestartButStillCheckBinding() {
        var watchdog = AudioRoutingWatchdog()
        var bindingChecks = 0
        for _ in 0..<100 {
            let actions = tick(&watchdog, backgrounded: true, renderCallbacks: 0, captureCallbacks: 0)
            if actions.checkOutputBinding { bindingChecks += 1 }
            XCTAssertFalse(actions.recoverStall)
            XCTAssertFalse(actions.resetRecoveryAttempts)
        }
        XCTAssertEqual(bindingChecks, 10)
    }

    func testBackgroundHardStopStillRequestsRecovery() {
        var watchdog = AudioRoutingWatchdog()
        for window in 1...30 {
            let actions = tick(&watchdog, backgrounded: true, running: false)
            XCTAssertEqual(actions.recoverStall, window == 30)
            XCTAssertFalse(actions.checkOutputBinding)
        }
    }

    func testForegroundStallRequiresThirtyNewWindowsAfterBackground() {
        var watchdog = AudioRoutingWatchdog()
        for _ in 0..<100 {
            _ = tick(&watchdog, backgrounded: true, renderCallbacks: 0, captureCallbacks: 0)
        }
        for window in 1...30 {
            let actions = tick(&watchdog, renderCallbacks: 0)
            XCTAssertEqual(actions.recoverStall, window == 30)
        }
    }

    func testFeedbackMustBeContinuousAndOnTheRoutedPath() {
        var watchdog = AudioRoutingWatchdog()
        for _ in 0..<49 {
            XCTAssertFalse(tick(&watchdog, backgrounded: true, clipping: true, capturePeakDb: 0).stopFeedback)
        }
        _ = tick(&watchdog, backgrounded: true, routed: false, clipping: true, capturePeakDb: 0)
        for window in 1...50 {
            XCTAssertEqual(
                tick(&watchdog, backgrounded: true, clipping: true, capturePeakDb: 0).stopFeedback,
                window == 50
            )
        }
    }

    func testSingleFullScaleTransientDoesNotStopAudio() {
        var watchdog = AudioRoutingWatchdog()
        for _ in 0..<100 {
            XCTAssertFalse(tick(&watchdog, clipping: true, capturePeakDb: 0).stopFeedback)
            XCTAssertFalse(tick(&watchdog, capturePeakDb: -0.1).stopFeedback)
        }
    }

    func testStoppedOrResetPathDoesNotReuseFeedbackHistory() {
        var watchdog = AudioRoutingWatchdog()
        for _ in 0..<49 {
            _ = tick(&watchdog, clipping: true, capturePeakDb: 0)
        }
        XCTAssertEqual(tick(&watchdog, requested: false), AudioRoutingWatchdog.Actions())
        XCTAssertFalse(tick(&watchdog, clipping: true, capturePeakDb: 0).stopFeedback)
        watchdog.reset()
        XCTAssertFalse(tick(&watchdog, clipping: true, capturePeakDb: 0).stopFeedback)
    }

    func testPendingRecoveryIsNotDuplicatedAndHealthyWindowsResetBudget() {
        var watchdog = AudioRoutingWatchdog()
        for _ in 0..<40 {
            XCTAssertFalse(tick(&watchdog, running: false, recoveryPending: true).recoverStall)
        }
        XCTAssertTrue(tick(&watchdog, running: false).recoverStall)
        for window in 1...100 {
            XCTAssertEqual(tick(&watchdog).resetRecoveryAttempts, window == 100)
        }
    }
}
