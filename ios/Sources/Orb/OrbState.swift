import Foundation

/// The orb's conversational state. Phase 2 only ever renders `.idle`; the
/// remaining cases exist so the public interface does not change later.
public enum OrbState: String, CaseIterable, Sendable {
    case idle
    case listening
    case speaking

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        }
    }
}
