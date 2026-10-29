import Foundation
import Observation

@MainActor @Observable
public final class ReminderRules {
    public private(set) var persistenceError: String?
    private let state: AppState

    public init(state: AppState) { self.state = state }

    public func visibility(of occurrences: [MeetingOccurrence], at now: Date) -> ReminderVisibility {
        ReminderVisibilityPolicy.evaluate(occurrences: occurrences, rules: state.hiddenEvents, suppressions: state.countdownSuppressions, at: now)
    }

    public func hide(_ event: MeetingOccurrence, scope: HideScope, calendarTitle: String, in occurrences: [MeetingOccurrence], at now: Date) throws {
        guard event.end > now else { throw ReminderRuleError.eventEnded }
        let rule = try ReminderVisibilityPolicy.rule(for: event, scope: scope, calendarTitle: calendarTitle, in: occurrences)
        guard ReminderVisibilityPolicy.matching(rule, in: occurrences).contains(where: { $0.key == event.key }) else {
            throw ReminderRuleError.ambiguousOccurrence
        }
        let duplicate = state.hiddenEvents.contains {
            $0.scope == rule.scope && $0.calendarID == rule.calendarID && $0.sourceID == rule.sourceID &&
            $0.localItemID == rule.localItemID && $0.externalItemID == rule.externalItemID && $0.originalOccurrenceDate == rule.originalOccurrenceDate
        }
        if !duplicate { try state.setHiddenEvents(state.hiddenEvents + [rule]) }
    }

    public func unhide(_ id: UUID) throws { try state.setHiddenEvents(state.hiddenEvents.filter { $0.id != id }) }
    public func unhideAll() throws { try state.setHiddenEvents([]) }

    public func suppressCountdown(_ event: MeetingOccurrence, at now: Date) throws {
        guard event.end > now else { throw ReminderRuleError.eventEnded }
        let countdown = MeetingCountdown(meeting: event, at: now)
        guard countdown.canSuppress else { throw ReminderRuleError.finalMinute }
        let next = state.countdownSuppressions.filter { $0.occurrence != event.key }
            + [CountdownSuppression(occurrence: event.key, phase: countdown.phase, boundary: countdown.boundary)]
        try state.setCountdownSuppressions(next)
    }

    public func restoreCountdown(_ key: OccurrenceKey) throws {
        try state.setCountdownSuppressions(state.countdownSuppressions.filter { $0.occurrence != key })
    }

    /// Persist only actual boundary/metadata changes, not every display tick.
    public func reconcile(occurrences: [MeetingOccurrence], at now: Date) {
        let result = visibility(of: occurrences, at: now)
        do {
            if result.retainedRules != state.hiddenEvents { try state.setHiddenEvents(result.retainedRules) }
            if result.retainedSuppressions != state.countdownSuppressions { try state.setCountdownSuppressions(result.retainedSuppressions) }
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }
}
