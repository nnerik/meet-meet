import Foundation
import Observation

/// A final visual reminder, independent of countdown visibility and audio arming.
/// Unlike audio, it catches up anywhere within the upcoming lead-time interval.
@MainActor @Observable
public final class SplashCueSession {
    public private(set) var meetings: [MeetingOccurrence] = []
    public private(set) var errorMessage: String?
    private let state: AppState
    private var locallyDismissed: Set<OccurrenceKey> = []

    public init(state: AppState) { self.state = state }

    public func reset() { meetings = [] }

    /// Callers provide reminder-filtered occurrences, before temporary HUD suppression.
    public func update(occurrences: [MeetingOccurrence], isActive: Bool, at now: Date) {
        let unsafeRecords: Set<AppStateRecord> = [.dismissedSplashCues, .hiddenEvents, .pause, .selectedCalendars, .preferences]
        guard !state.recoveryNotices.contains(where: { unsafeRecords.contains($0.record) }) else {
            reset()
            errorMessage = "Splash cues are disabled because saved reminder records could not be read. Restore those records or use the app version that saved them."
            return
        }
        guard isActive, state.preferences.splashCueEnabled,
              now.timeIntervalSinceReferenceDate.isFinite, (try? state.preferences.validated()) != nil else {
            reset()
            return
        }
        let counts = Dictionary(grouping: occurrences, by: \.key)
        let dismissed = state.dismissedSplashCues.union(locallyDismissed)
        let lead = Double(state.preferences.splashLeadMinutes) * 60
        meetings = occurrences.filter {
            $0.isEligibleMeeting && state.selectedCalendarIDs.contains($0.calendarID) && counts[$0.key]?.count == 1 &&
                !dismissed.contains($0.key) && $0.start > now && $0.start.timeIntervalSince(now) <= lead
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.id < $1.id
        }
    }

    public func dismiss() {
        guard !meetings.isEmpty else { return }
        locallyDismissed.formUnion(meetings.map(\.key))
        reset()
        do {
            try state.setDismissedSplashCues(state.dismissedSplashCues.union(locallyDismissed))
            errorMessage = nil
        } catch {
            errorMessage = "The splash was dismissed, but its dismissal could not be saved. " + error.localizedDescription
        }
    }
}
