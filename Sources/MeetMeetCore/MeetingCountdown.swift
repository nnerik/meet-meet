import Foundation

/// One timestamp's countdown decisions, shared by HUD, menu and suppression.
/// Callers own eligibility and ensure the occurrence has not ended.
struct MeetingCountdown {
    let phase: CountdownPhase
    let boundary: Date
    let remaining: TimeInterval

    init(meeting: MeetingOccurrence, at now: Date) {
        phase = meeting.phase(at: now) == .upcoming ? .upcoming : .ongoing
        boundary = phase == .upcoming ? meeting.start : meeting.end
        remaining = boundary.timeIntervalSince(now)
    }

    var canSuppress: Bool { remaining > 60 }
    var isFinalMinute: Bool { remaining > 0 && remaining <= 60 }
}
