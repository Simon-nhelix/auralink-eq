import Foundation

/// The last applied state takes precedence over a preset's saved revisions.
/// A/B can inspect the snapshot without consuming it; rollback consumes it.
public struct PresetUndoState {
    public var before: EQPreset?

    public init(before: EQPreset? = nil) { self.before = before }

    public mutating func captureBeforeApplying(current: EQPreset, next: EQPreset) {
        if current.normalized() != next.normalized() {
            before = current.normalized()
        }
    }

    public mutating func rollbackTarget(
        current: EQPreset,
        previousRevision: () throws -> EQPreset?
    ) rethrows -> EQPreset? {
        if let snapshot = before, snapshot.normalized() != current.normalized() {
            before = nil
            return snapshot.normalized()
        }
        if let revision = try previousRevision(), revision.normalized() != current.normalized() {
            before = nil
            return revision.normalized()
        }
        return nil
    }
}
