import CoreGraphics
import Foundation
import Observation

/// Owns the preferred anchor independently of temporary expansion and clamping.
/// Failed saves retain a live position, never a claim of durable persistence.
@MainActor @Observable
public final class HUDPlacementSession {
    public private(set) var positionError: String?
    private let state: AppState
    private var transientPosition: HUDPosition?

    public init(state: AppState) { self.state = state }

    private var preferredPosition: HUDPosition? { transientPosition ?? state.hudPosition }

    public func layout(rowCount: Int, expanded: Bool, longestCountdownLength: Int,
                       displays: [HUDDisplay], legacyScrollerWidth: Double = 0) -> HUDLayout? {
        // Recover using compact geometry so a temporary title expansion cannot
        // turn left-edge clamping into a new preferred anchor.
        if HUDLayoutPolicy.needsPositionRecovery(preferredPosition, displays: displays),
           let compact = HUDLayoutPolicy.layout(rowCount: rowCount, expanded: false, longestCountdownLength: longestCountdownLength,
                                                preferredPosition: preferredPosition, displays: displays, legacyScrollerWidth: legacyScrollerWidth),
           let recovered = HUDLayoutPolicy.position(for: compact.frame, displays: displays) {
            save(recovered)
        }
        return HUDLayoutPolicy.layout(rowCount: rowCount, expanded: expanded, longestCountdownLength: longestCountdownLength,
                                      preferredPosition: preferredPosition, displays: displays, legacyScrollerWidth: legacyScrollerWidth)
    }

    /// The native caller distinguishes authoritative movement from layout moves.
    public func recordMove(to frame: CGRect, displays: [HUDDisplay]) {
        guard let position = HUDLayoutPolicy.position(for: frame, displays: displays) else { return }
        save(position)
    }

    private func save(_ position: HUDPosition) {
        do {
            if position != state.hudPosition { try state.setHUDPosition(position) }
            transientPosition = nil
            positionError = nil
        } catch {
            transientPosition = position
            positionError = "Position could not be saved. " + error.localizedDescription
        }
    }
}
