import XCTest
@testable import AuralinkCore

final class ControlPermissionGateTests: XCTestCase {
    func testReadOnlyForbidsEveryWrite() {
        for kind in [ControlWriteKind.createPreset, .applyLive] {
            XCTAssertEqual(PermissionMode.readOnly.decision(for: kind, confirmed: false), .forbidden)
            XCTAssertEqual(PermissionMode.readOnly.decision(for: kind, confirmed: true), .forbidden)
        }
    }

    func testAskBeforeWriteRequiresConfirmation() {
        XCTAssertEqual(
            PermissionMode.askBeforeWrite.decision(for: .createPreset, confirmed: false),
            .needsConfirm
        )
        XCTAssertEqual(
            PermissionMode.askBeforeWrite.decision(for: .applyLive, confirmed: false),
            .needsConfirm
        )
        XCTAssertEqual(
            PermissionMode.askBeforeWrite.decision(for: .applyLive, confirmed: true),
            .allow
        )
        XCTAssertEqual(
            PermissionMode.askBeforeWrite.decision(for: .createPreset, confirmed: true),
            .allow
        )
    }

    func testAllowPresetCreationSavesWithoutConfirmButNotLiveApply() {
        XCTAssertEqual(
            PermissionMode.allowPresetCreation.decision(for: .createPreset, confirmed: false),
            .allow
        )
        XCTAssertEqual(
            PermissionMode.allowPresetCreation.decision(for: .applyLive, confirmed: false),
            .needsConfirm
        )
        XCTAssertEqual(
            PermissionMode.allowPresetCreation.decision(for: .applyLive, confirmed: true),
            .allow
        )
    }

    func testFullControlAllowsUnconfirmedWrites() {
        XCTAssertEqual(
            PermissionMode.fullControl.decision(for: .createPreset, confirmed: false),
            .allow
        )
        XCTAssertEqual(
            PermissionMode.fullControl.decision(for: .applyLive, confirmed: false),
            .allow
        )
    }
}
