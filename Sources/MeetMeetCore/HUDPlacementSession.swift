import CoreGraphics
import Foundation
import Observation

/// Owns the preferred anchor independently of temporary expansion and clamping.
/// Failed saves retain a live position, never a claim of durable persistence.
@MainActor @Observable
public final class HUDPlacementSession {
    public enum MovementSource: Equatable, Sendable { case view, nativeWindow }

    public enum Update: Equatable, Sendable {
        case hidden
        case unchanged(expanded: Bool)
        case layout(HUDLayout, expanded: Bool)
    }

    private struct Movement {
        var source: MovementSource
        var accountedFrame: CGRect
        let expanded: Bool
    }

    public private(set) var positionError: String?
    private let state: AppState
    private var transientPosition: HUDPosition?
    private var movement: Movement?
    private var expanded = false
    private var lastDisplays: [HUDDisplay]?

    public init(state: AppState) { self.state = state }

    private var preferredPosition: HUDPosition? { transientPosition ?? state.hudPosition }

    public func update(rowCount: Int, expanded requestedExpansion: Bool, longestCountdownLength: Int,
                       displays: [HUDDisplay], legacyScrollerWidth: Double = 0, isPointerDown: Bool = false) -> Update {
        let displaysChanged = lastDisplays != displays
        if movement?.source == .nativeWindow && !isPointerDown { movement = nil }
        guard rowCount > 0 else {
            // Refresh can briefly clear the rows while performDrag still owns
            // pointer capture. Only its completion (or stop) retires that move.
            expanded = false
            return .hidden
        }
        expanded = movement?.expanded ?? requestedExpansion
        if movement != nil && !displaysChanged { return .unchanged(expanded: expanded) }
        guard let layout = layout(rowCount: rowCount, expanded: expanded, longestCountdownLength: longestCountdownLength,
                                  displays: displays, legacyScrollerWidth: legacyScrollerWidth) else {
            resetMovement()
            return .hidden
        }
        // Display recovery is not a user move. A later view-drag completion
        // must not persist the temporarily expanded/clamped recovery frame.
        lastDisplays = displays
        movement?.accountedFrame = layout.frame
        return .layout(layout, expanded: expanded)
    }

    public func beginMove(at frame: CGRect, source: MovementSource) {
        if movement == nil { movement = Movement(source: source, accountedFrame: frame, expanded: expanded) }
        else if source == .view { movement?.source = .view }
    }

    /// Native movement can bypass or outlive the view callbacks. Capture the
    /// authoritative anchor before any countdown refresh can reapply an old one.
    public func recordMove(to frame: CGRect, displays: [HUDDisplay], isPointerDown: Bool = false) {
        if isPointerDown { beginMove(at: frame, source: .nativeWindow) }
        saveFrame(frame, displays: displays)
        movement?.accountedFrame = frame
    }

    public func endMove(at frame: CGRect, displays: [HUDDisplay], isPointerDown: Bool = false) {
        guard let previous = movement else { return }
        if frame.origin != previous.accountedFrame.origin { saveFrame(frame, displays: displays) }
        movement = isPointerDown ? Movement(source: .nativeWindow, accountedFrame: frame, expanded: previous.expanded) : nil
    }

    public func resetMovement() {
        movement = nil
        expanded = false
        lastDisplays = nil
    }

    private func layout(rowCount: Int, expanded: Bool, longestCountdownLength: Int,
                        displays: [HUDDisplay], legacyScrollerWidth: Double) -> HUDLayout? {
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

    private func saveFrame(_ frame: CGRect, displays: [HUDDisplay]) {
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
