import Foundation
import Observation

/// Visual reminders catch up within either phase's lead-time interval,
/// independently of countdown visibility and audio arming.
@MainActor @Observable
public final class SplashCueSession {
    public private(set) var meetings: [MeetingOccurrence] = []
    public private(set) var endMeetings: [MeetingOccurrence] = []
    public var preferences: AppPreferences { state.preferences }
    public private(set) var errorMessage: String?
    private let state: AppState
    private var locallyDismissed: Set<OccurrenceKey> = []
    private var locallyDismissedEnd: Set<OccurrenceKey> = []

    public init(state: AppState) { self.state = state }

    public func reset() { meetings = []; endMeetings = [] }

    /// Callers provide reminder-filtered occurrences, before temporary HUD suppression.
    public func update(occurrences: [MeetingOccurrence], isActive: Bool, at now: Date) {
        let unsafeRecords: Set<AppStateRecord> = [.dismissedSplashCues, .dismissedEndSplashCues, .hiddenEvents, .pause, .selectedCalendars, .preferences]
        guard !state.recoveryNotices.contains(where: { unsafeRecords.contains($0.record) }) else {
            reset()
            errorMessage = "Splash cues are disabled because saved reminder records could not be read. Restore those records or use the app version that saved them."
            return
        }
        guard isActive,
              now.timeIntervalSinceReferenceDate.isFinite, (try? state.preferences.validated()) != nil else {
            reset()
            return
        }
        let counts = Dictionary(grouping: occurrences, by: \.key)
        let dismissed = state.dismissedSplashCues.union(locallyDismissed)
        let dismissedEnd = state.dismissedEndSplashCues.union(locallyDismissedEnd)
        let lead = Double(state.preferences.splashLeadMinutes) * 60
        let eligible = occurrences.filter {
            $0.isEligibleMeeting && state.selectedCalendarIDs.contains($0.calendarID) && counts[$0.key]?.count == 1
        }
        meetings = eligible.filter {
            state.preferences.splashCueEnabled && !dismissed.contains($0.key) &&
                $0.start > now && $0.start.timeIntervalSince(now) <= lead
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.id < $1.id
        }
        let endLead = Double(state.preferences.endSplashLeadMinutes) * 60
        endMeetings = eligible.filter {
            state.preferences.endSplashCueEnabled && !dismissedEnd.contains($0.key) &&
                $0.start <= now && $0.end > now && $0.end.timeIntervalSince(now) <= endLead
        }.sorted {
            if $0.end != $1.end { return $0.end < $1.end }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.id < $1.id
        }
    }

    public func dismiss() {
        guard !meetings.isEmpty || !endMeetings.isEmpty else { return }
        locallyDismissed.formUnion(meetings.map(\.key))
        locallyDismissedEnd.formUnion(endMeetings.map(\.key))
        reset()
        do {
            try state.setDismissedSplashCues(state.dismissedSplashCues.union(locallyDismissed))
            try state.setDismissedEndSplashCues(state.dismissedEndSplashCues.union(locallyDismissedEnd))
            errorMessage = nil
        } catch {
            errorMessage = "The splash was dismissed, but its dismissal could not be saved. " + error.localizedDescription
        }
    }
}
