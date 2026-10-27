import Foundation

public enum MeetingReminderAction: Int, Sendable {
    case hideOccurrence, hideSeries, suppressCountdown, restoreCountdown
}

public struct MeetingMenuPresentation: Equatable, Sendable {
    public let remainingToday: [MeetingMenuEntry]
    public let tomorrow: [MeetingMenuEntry]
}

/// Decisions captured together with the session's reconciled meeting snapshot.
/// Native callers render these values without consulting another clock.
public struct MeetingMenuEntry: Equatable, Sendable {
    public enum CountdownAction: Equatable, Sendable {
        case restore
        case suppress(isEnabled: Bool)
    }

    public let meeting: MeetingOccurrence
    public let calendarTitle: String
    public let phase: CountdownPhase
    public let boundary: Date
    public let canHideOccurrence: Bool
    public let canHideSeries: Bool
    public let countdownAction: CountdownAction

    init(meeting: MeetingOccurrence, calendarTitle: String, isCountdownSuppressed: Bool, at now: Date) {
        self.meeting = meeting
        self.calendarTitle = calendarTitle
        phase = meeting.start > now ? .upcoming : .ongoing
        boundary = phase == .upcoming ? meeting.start : meeting.end
        canHideOccurrence = meeting.identityEvidence != nil
        canHideSeries = meeting.identityEvidence?.isRecurring == true || meeting.identityEvidence?.isDetached == true
        countdownAction = isCountdownSuppressed ? .restore : .suppress(isEnabled: boundary.timeIntervalSince(now) > 60)
    }
}
