import Foundation

public struct ReminderVisibility: Equatable, Sendable {
    public let occurrences: [MeetingOccurrence]
    public let suppressedCountdowns: Set<OccurrenceKey>
    public let retainedRules: [HiddenEventRule]
    public let retainedSuppressions: [CountdownSuppression]
}

public enum ReminderVisibilityPolicy {
    public static func evaluate(occurrences: [MeetingOccurrence], rules: [HiddenEventRule], suppressions: [CountdownSuppression], at now: Date) -> ReminderVisibility {
        var hidden: [MeetingOccurrence] = []
        var retainedRules: [HiddenEventRule] = []
        for rule in rules {
            let matches = matching(rule, in: occurrences)
            hidden.append(contentsOf: matches)
            // An unmatched saved end is not proof an event wasn't rescheduled.
            // Keep the rule at the exact end boundary, including zero-offset audio.
            let knownEnded = rule.scope == .occurrence && matches.count == 1 && matches[0].end < now
            if !knownEnded { retainedRules.append(rule) }
        }

        var suppressed: Set<OccurrenceKey> = []
        var retainedSuppressions: [CountdownSuppression] = []
        for record in suppressions {
            let matches = occurrences.filter { $0.key == record.occurrence }
            guard matches.count == 1 else {
                if record.boundary > now { retainedSuppressions.append(record) }
                continue
            }
            let event = matches[0]
            guard event.end > now else { continue }
            let phase: CountdownPhase = event.start > now ? .upcoming : .ongoing
            guard phase == record.phase else { continue }
            let boundary = phase == .upcoming ? event.start : event.end
            guard boundary.timeIntervalSince(now) > 60 else { continue }
            suppressed.insert(event.key)
            retainedSuppressions.append(CountdownSuppression(occurrence: record.occurrence, phase: phase, boundary: boundary))
        }
        return ReminderVisibility(occurrences: occurrences.filter { !hidden.contains($0) }, suppressedCountdowns: suppressed,
                                  retainedRules: retainedRules, retainedSuppressions: retainedSuppressions)
    }

    public static func matching(_ rule: HiddenEventRule, in occurrences: [MeetingOccurrence]) -> [MeetingOccurrence] {
        guard let localID = rule.localItemID, !localID.isEmpty else { return [] }
        let scoped = occurrences.filter { event in
            guard event.calendarID == rule.calendarID, let evidence = event.identityEvidence else { return false }
            if let source = rule.sourceID, evidence.sourceID != source { return false }
            return true
        }
        let local = scoped.filter { event in
            guard let evidence = event.identityEvidence, evidence.localItemID == localID else { return false }
            if let previous = rule.externalItemID, let current = evidence.externalItemID, previous != current { return false }
            return true
        }
        if rule.scope == .occurrence {
            var candidates = local.filter { event in
                guard let evidence = event.identityEvidence else { return false }
                if let original = rule.originalOccurrenceDate {
                    guard evidence.isRecurring || evidence.isDetached else { return false }
                    return (evidence.originalOccurrenceDate ?? event.start) == original
                }
                return !evidence.isRecurring && !evidence.isDetached
            }
            if let original = rule.originalOccurrenceDate, let external = rule.externalItemID, !external.isEmpty {
                let family = scoped.filter { $0.identityEvidence?.externalItemID == external }
                let bases = Set(family.filter { $0.identityEvidence?.isDetached == false }.compactMap { $0.identityEvidence?.localItemID })
                if bases == [localID] {
                    let keys = Set(candidates.map(\.key))
                    candidates += family.filter {
                        $0.identityEvidence?.isDetached == true && $0.identityEvidence?.originalOccurrenceDate == original && !keys.contains($0.key)
                    }
                }
            }
            return candidates.count == 1 ? candidates : []
        }

        var matches = local.filter { $0.identityEvidence?.isRecurring == true || $0.identityEvidence?.isDetached == true }
        guard !matches.isEmpty, let external = rule.externalItemID, !external.isEmpty else { return matches }
        let family = scoped.filter { $0.identityEvidence?.externalItemID == external }
        let baseIDs = Set(family.filter { $0.identityEvidence?.isDetached == false }.compactMap { $0.identityEvidence?.localItemID })
        // Extend to detached exceptions only with a currently identifiable,
        // unambiguous parent. External IDs alone can collide, even in one calendar.
        guard baseIDs == [localID] else { return matches }
        let keys = Set(matches.map(\.key))
        matches += family.filter {
            $0.identityEvidence?.isDetached == true && $0.identityEvidence?.originalOccurrenceDate != nil && !keys.contains($0.key)
        }
        return matches
    }

    public static func rule(for event: MeetingOccurrence, scope: HideScope, calendarTitle: String, in occurrences: [MeetingOccurrence]) throws -> HiddenEventRule {
        guard let evidence = event.identityEvidence, !evidence.localItemID.isEmpty else { throw ReminderRuleError.identityUnavailable }
        var localID = evidence.localItemID
        if scope == .series {
            guard evidence.isRecurring || evidence.isDetached else { throw ReminderRuleError.notRecurring }
        }
        if evidence.isDetached {
            let parents = occurrences.filter {
                $0.calendarID == event.calendarID && $0.identityEvidence?.sourceID == evidence.sourceID &&
                evidence.externalItemID?.isEmpty == false && $0.identityEvidence?.externalItemID == evidence.externalItemID &&
                $0.identityEvidence?.isDetached == false && $0.identityEvidence?.isRecurring == true
            }
            let parentIDs = Set(parents.compactMap { $0.identityEvidence?.localItemID })
            if parentIDs.count == 1, let parent = parentIDs.first { localID = parent }
            else if scope == .series { throw ReminderRuleError.seriesUnavailable }
        }
        let original: Date? = scope == .occurrence && (evidence.isRecurring || evidence.isDetached)
            ? evidence.originalOccurrenceDate ?? event.start : nil
        return HiddenEventRule(scope: scope, calendarID: event.calendarID, sourceID: evidence.sourceID,
                               localItemID: localID, externalItemID: evidence.externalItemID, originalOccurrenceDate: original,
                               knownEnd: scope == .occurrence ? event.end : nil,
                               title: MeetingText.displayTitle(event.title), calendarTitle: calendarTitle)
    }
}

public enum ReminderRuleError: Error, LocalizedError, Equatable {
    case identityUnavailable, notRecurring, seriesUnavailable, ambiguousOccurrence, finalMinute, eventEnded
    case calendarUnavailable, occurrenceUnavailable, invalidTime

    public var errorDescription: String? {
        switch self {
        case .identityUnavailable: "This meeting cannot be identified reliably enough to hide."
        case .notRecurring: "This meeting is not part of an identifiable recurring series."
        case .seriesUnavailable: "This exception's parent series cannot be identified confidently. Hide just this meeting instead."
        case .ambiguousOccurrence: "Calendar identity is ambiguous. The meeting was left visible."
        case .finalMinute: "The countdown is already in its final minute."
        case .eventEnded: "This meeting has already ended."
        case .calendarUnavailable: "Calendar information is not ready. Refresh calendars and try again."
        case .occurrenceUnavailable: "This meeting is no longer available. Refresh calendars and try again."
        case .invalidTime: "The current time is unavailable. Try again when the system clock is available."
        }
    }
}
