import XCTest
@testable import AuralinkCore

final class PresetUndoStateTests: XCTestCase {
    private func preset(_ id: String) -> EQPreset {
        EQPreset(id: id, name: id, bands: EQBand.defaultBands()).normalized()
    }

    func testApplyRestoresPreviousPresetBeforeConsultingNewPresetsRevisions() throws {
        let a = preset("a")
        let b = preset("b")
        var undo = PresetUndoState()
        undo.captureBeforeApplying(current: a, next: b)
        enum RevisionError: Error { case unreadable }
        let target = try undo.rollbackTarget(current: b) { throw RevisionError.unreadable }
        XCTAssertEqual(target, a)
        XCTAssertNil(undo.before)
    }

    func testSamePresetAuditionDoesNotErasePreviousSnapshot() {
        let a = preset("a"), b = preset("b")
        var undo = PresetUndoState()
        undo.captureBeforeApplying(current: a, next: b)
        undo.captureBeforeApplying(current: b, next: b)
        XCTAssertEqual(undo.rollbackTarget(current: b) { nil }, a)
    }

    func testSameIDUnsavedChangesRestoreExactPreviousBands() {
        let original = preset("a")
        var edited = original
        edited.bands[0].gainDb = 3
        edited.bands[0].enabled = true
        var undo = PresetUndoState()
        undo.captureBeforeApplying(current: original, next: edited)
        XCTAssertEqual(undo.rollbackTarget(current: edited) { nil }, original)
    }

    func testLatestApplyReplacesEarlierSnapshotAndRollbackDoesNotToggle() {
        let a = preset("a"), b = preset("b"), c = preset("c")
        var undo = PresetUndoState()
        undo.captureBeforeApplying(current: a, next: b)
        undo.captureBeforeApplying(current: b, next: c)
        XCTAssertEqual(undo.rollbackTarget(current: c) { nil }, b)
        XCTAssertNil(undo.rollbackTarget(current: b) { nil })
    }

    func testSavedRevisionRemainsAvailableWithoutLiveUndo() {
        let current = preset("a")
        var revision = current
        revision.version = 0
        var undo = PresetUndoState(before: current)
        XCTAssertEqual(undo.rollbackTarget(current: current) { revision }, revision)
        XCTAssertNil(undo.before)
        XCTAssertNil(undo.rollbackTarget(current: revision) { revision })
    }
}
