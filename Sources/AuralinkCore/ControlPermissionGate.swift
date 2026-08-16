import Foundation

/// Kind of ControlServer / MCP write. Live-audio changes are stricter than
/// library writes so `allow_preset_creation` can save without applying.
public enum ControlWriteKind: String, Sendable {
    /// Create or update a preset / knowledge file. Does not change live audio.
    case createPreset
    /// Change the live path: apply, audition, rollback, output, or routing.
    case applyLive
}

/// Outcome of a permission-mode check for one write.
public enum ControlWriteDecision: String, Equatable, Sendable {
    case allow
    case needsConfirm
    case forbidden
}

public extension PermissionMode {
    /// Decide whether a ControlServer/MCP write may proceed.
    ///
    /// `confirmed` is the client-asserted "the user asked for this change"
    /// flag. It never overrides `.readOnly`.
    func decision(for kind: ControlWriteKind, confirmed: Bool) -> ControlWriteDecision {
        switch self {
        case .readOnly:
            return .forbidden
        case .askBeforeWrite:
            return confirmed ? .allow : .needsConfirm
        case .allowPresetCreation:
            switch kind {
            case .createPreset:
                return .allow
            case .applyLive:
                return confirmed ? .allow : .needsConfirm
            }
        case .fullControl:
            return .allow
        }
    }
}
