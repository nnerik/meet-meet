import Foundation
import Observation

/// Automatic visual cues and manually opened meeting info share presentation,
/// but only automatically presented cues participate in dismissal history.
@MainActor @Observable
public final class SplashCueSession {
    public private(set) var meetings: [MeetingOccurrence] = []
    public private(set) var endMeetings: [MeetingOccurrence] = []
    public private(set) var infoMeetings: [MeetingOccurrence] = []
    /// Explicit opens and newly due cues can raise an already-visible panel.
    public private(set) var presentationRevision = 0
    public var preferences: AppPreferences { state.preferences }
    public private(set) var errorMessage: String?
    private let state: AppState
    private var locallyDismissed: Set<OccurrenceKey> = []
    private var locallyDismissedEnd: Set<OccurrenceKey> = []
    private var availableMeetings: [MeetingOccurrence] = []
    private var manuallyOpened: Set<OccurrenceKey> = []
    private var automaticallyOpened: Set<OccurrenceKey> = []
    private var previousUpdate: Date?
    private var previousOccurrences: [MeetingOccurrence] = []
    private var previousPreferences: AppPreferences?
    private var openedZeroEndCues: [OccurrenceKey: Date] = [:]

    public init(state: AppState) { self.state = state }

    public func reset() {
        suspend()
        manuallyOpened = []
        automaticallyOpened = []
        openedZeroEndCues = [:]
    }

    /// Hide untrusted snapshots during refresh, retaining only the identities
    /// to restore after fresh data arrives (including a transition into ongoing).
    public func suspend() {
        meetings = []
        endMeetings = []
        infoMeetings = []
        availableMeetings = []
        previousUpdate = nil
        previousOccurrences = []
        previousPreferences = nil
    }

    public func showMeetingInfo(for key: OccurrenceKey) {
        guard availableMeetings.contains(where: { $0.key == key }) else { return }
        manuallyOpened.insert(key)
        updateInfoMeetings()
        presentationRevision += 1
    }

    /// Callers provide reminder-filtered occurrences, before temporary HUD suppression.
    public func update(occurrences: [MeetingOccurrence], isActive: Bool, at now: Date) {
        let unsafeRecords: Set<AppStateRecord> = [.hiddenEvents, .pause, .selectedCalendars, .preferences]
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
        let trusted = occurrences.filter {
            $0.isEligibleMeeting && state.selectedCalendarIDs.contains($0.calendarID) && counts[$0.key]?.count == 1
        }
        let eligible = trusted.filter { $0.end > now }
        availableMeetings = eligible
        // Dismissal history authorizes automatic reminders, not explicit opens
        // of otherwise trusted meeting info. Never overwrite unreadable history.
        let canPresentAutomatically = !state.recoveryNotices.contains {
            $0.record == .dismissedSplashCues || $0.record == .dismissedEndSplashCues
        }
        if !canPresentAutomatically {
            errorMessage = "Automatic visual cues are disabled because saved cue dismissals could not be read. You can still open meeting info from the countdown."
        }
        let previousStarts = Set(meetings.map(\.key))
        let previousEnds = Set(endMeetings.map(\.key))
        // Native ticks need not land exactly on a boundary. Only cross a zero-
        // offset deadline observed in the prior trusted snapshot, never catch up
        // after launch, interruption, edits or a setting change.
        func reachedBoundary(_ event: MeetingOccurrence, end: Bool) -> Bool {
            let boundary = end ? event.end : event.start
            if boundary == now { return true }
            guard let previousUpdate, previousUpdate < boundary, boundary <= now,
                  now.timeIntervalSince(previousUpdate) <= 5,
                  previousPreferences == state.preferences else { return false }
            return previousOccurrences.contains {
                $0.key == event.key && $0.start == event.start && $0.end == event.end
            }
        }
        meetings = eligible.filter {
            canPresentAutomatically && state.preferences.splashCueEnabled && !dismissed.contains($0.key) &&
                (lead == 0 ? reachedBoundary($0, end: false) : $0.start > now && $0.start.timeIntervalSince(now) <= lead)
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.id < $1.id
        }
        let endLead = Double(state.preferences.endSplashLeadMinutes) * 60
        endMeetings = trusted.filter { event in
            let retainedZeroCue = openedZeroEndCues[event.key] == event.end && event.end <= now
            return canPresentAutomatically && state.preferences.endSplashCueEnabled && !dismissedEnd.contains(event.key) &&
                (endLead == 0 ? reachedBoundary(event, end: true) || retainedZeroCue :
                    event.start <= now && event.end > now && event.end.timeIntervalSince(now) <= endLead)
        }.sorted {
            if $0.end != $1.end { return $0.end < $1.end }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.id < $1.id
        }
        let startKeys = Set(meetings.map(\.key))
        let endKeys = Set(endMeetings.map(\.key))
        openedZeroEndCues = endLead == 0 ? Dictionary(uniqueKeysWithValues: endMeetings.map { ($0.key, $0.end) }) : [:]
        if !startKeys.subtracting(previousStarts).isEmpty || !endKeys.subtracting(previousEnds).isEmpty {
            presentationRevision += 1
        }
        let availableKeys = Set(eligible.map(\.key))
        manuallyOpened.formIntersection(availableKeys)
        automaticallyOpened = canPresentAutomatically && state.preferences.splashCueEnabled
            ? automaticallyOpened.union(startKeys).intersection(availableKeys).subtracting(dismissed) : []
        updateInfoMeetings()
        previousUpdate = now
        previousOccurrences = trusted.filter { $0.end > now }
        previousPreferences = state.preferences
    }

    private func updateInfoMeetings() {
        let visible = manuallyOpened.union(automaticallyOpened)
        infoMeetings = availableMeetings.filter { visible.contains($0.key) }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.calendarID != $1.calendarID { return $0.calendarID < $1.calendarID }
            return $0.id < $1.id
        }
    }

    public func dismiss() {
        guard !infoMeetings.isEmpty || !endMeetings.isEmpty else { return }
        let startDismissals = automaticallyOpened.intersection(infoMeetings.map(\.key))
        let endDismissals = Set(endMeetings.map(\.key))
        locallyDismissed.formUnion(startDismissals)
        locallyDismissedEnd.formUnion(endDismissals)
        reset()
        do {
            if !startDismissals.isEmpty {
                try state.setDismissedSplashCues(state.dismissedSplashCues.union(locallyDismissed))
            }
            if !endDismissals.isEmpty {
                try state.setDismissedEndSplashCues(state.dismissedEndSplashCues.union(locallyDismissedEnd))
            }
            if !startDismissals.isEmpty || !endDismissals.isEmpty { errorMessage = nil }
        } catch {
            errorMessage = "Meeting info and cues were closed, but the cue dismissal could not be saved. " + error.localizedDescription
        }
    }
}
