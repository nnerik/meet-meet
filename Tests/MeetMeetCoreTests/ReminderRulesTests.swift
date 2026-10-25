import Foundation
import Testing
@testable import MeetMeetCore

private let reminderNow = Date(timeIntervalSince1970: 1_800_000_000)

private func reminderEvent(local: String = "item", calendar: String = "work", source: String = "source",
                           external: String? = "external", title: String = "Lunch", start: Double = 120, end: Double = 600,
                           original: Date? = nil, recurring: Bool = false, detached: Bool = false, id: String? = nil) -> MeetingOccurrence {
    let evidence = EventIdentityEvidence(sourceID: source, localItemID: local, externalItemID: external, eventID: nil,
                                         originalOccurrenceDate: original, isRecurring: recurring, isDetached: detached)
    let date = reminderNow.addingTimeInterval(start)
    return MeetingOccurrence(id: id ?? evidence.occurrenceID(start: date), calendarID: calendar, title: title,
                             start: date, end: reminderNow.addingTimeInterval(end), identityEvidence: evidence)
}

private func hideRule(_ event: MeetingOccurrence, scope: HideScope = .occurrence, events: [MeetingOccurrence]? = nil) throws -> HiddenEventRule {
    try ReminderVisibilityPolicy.rule(for: event, scope: scope, calendarTitle: "Work", in: events ?? [event])
}

private func visibility(_ events: [MeetingOccurrence], rules: [HiddenEventRule] = [], suppressions: [CountdownSuppression] = [], now: Date = reminderNow) -> ReminderVisibility {
    ReminderVisibilityPolicy.evaluate(occurrences: events, rules: rules, suppressions: suppressions, at: now)
}

@Test
func occurrenceHidingNeverMatchesByTitleOrCrossesCalendarSourceScopes() throws {
    let target = reminderEvent()
    let sameTitle = reminderEvent(local: "unrelated")
    let otherCalendar = reminderEvent(calendar: "personal")
    let otherSource = reminderEvent(source: "another-account")
    let rule = try hideRule(target)
    let result = visibility([target, sameTitle, otherCalendar, otherSource], rules: [rule])
    #expect(result.occurrences == [sameTitle, otherCalendar, otherSource])
}

@Test
func identifiableStandaloneEditsRemainHidden() throws {
    let original = reminderEvent()
    let renamed = reminderEvent(title: "Focused work", start: 900, end: 1_800)
    #expect(visibility([renamed], rules: [try hideRule(original)]).occurrences.isEmpty)
}

@Test
func hidingOneRecurringOccurrenceDoesNotHideTheNext() throws {
    let first = reminderEvent(local: "series", original: reminderNow.addingTimeInterval(120), recurring: true)
    let next = reminderEvent(local: "series", start: 86_520, end: 87_000, original: reminderNow.addingTimeInterval(86_520), recurring: true)
    #expect(visibility([first, next], rules: [try hideRule(first)]).occurrences == [next])
}

@Test
func aMovedExceptionFollowsItsOriginalOccurrenceWhenParentIsUnambiguous() throws {
    let original = reminderEvent(local: "series", original: reminderNow.addingTimeInterval(120), recurring: true)
    let next = reminderEvent(local: "series", start: 900, end: 1_200, original: reminderNow.addingTimeInterval(900), recurring: true)
    let moved = reminderEvent(local: "exception", start: 400, end: 800, original: original.start, detached: true)
    #expect(visibility([moved, next], rules: [try hideRule(original)]).occurrences == [next])
}

@Test
func seriesHidingIncludesConfidentlyLinkedEditedExceptions() throws {
    let first = reminderEvent(local: "series", original: reminderNow.addingTimeInterval(120), recurring: true)
    let next = reminderEvent(local: "series", start: 900, end: 1_200, original: reminderNow.addingTimeInterval(900), recurring: true)
    let exception = reminderEvent(local: "exception", start: 300, end: 700, original: reminderNow.addingTimeInterval(240), detached: true)
    let rule = try hideRule(first, scope: .series)
    #expect(visibility([first, next, exception], rules: [rule]).occurrences.isEmpty)
}

@Test
func ambiguousExternalIdentityDoesNotHideAnotherFamilyOrItsException() throws {
    let first = reminderEvent(local: "series", original: reminderNow.addingTimeInterval(120), recurring: true)
    let importedCopy = reminderEvent(local: "other-series", original: reminderNow.addingTimeInterval(120), recurring: true)
    let exception = reminderEvent(local: "exception", original: reminderNow.addingTimeInterval(240), detached: true)
    let result = visibility([first, importedCopy, exception], rules: [try hideRule(first, scope: .series)])
    #expect(result.occurrences == [importedCopy, exception])
}

@Test
func identifierChurnRecreationAndSeriesSplitsFailVisible() throws {
    let original = reminderEvent(local: "series", original: reminderNow.addingTimeInterval(120), recurring: true)
    let split = reminderEvent(local: "new-series", original: reminderNow.addingTimeInterval(120), recurring: true)
    #expect(visibility([split], rules: [try hideRule(original, scope: .series)]).occurrences == [split])
    let recreated = reminderEvent(local: "new-item")
    #expect(visibility([recreated], rules: [try hideRule(reminderEvent())]).occurrences == [recreated])
    let changedExternal = reminderEvent(external: "different-provider-item")
    #expect(visibility([changedExternal], rules: [try hideRule(reminderEvent())]).occurrences == [changedExternal])
}

@Test
func ambiguousOccurrenceIsLeftVisible() throws {
    let first = reminderEvent(id: "first")
    let second = reminderEvent(id: "second")
    #expect(visibility([first, second], rules: [try hideRule(first)]).occurrences == [first, second])
}

@Test
func externalOnlyRulesCannotSilentlyMatchAnUnrelatedItem() {
    let event = reminderEvent()
    let rule = HiddenEventRule(scope: .occurrence, calendarID: "work", externalItemID: "external", title: "Lunch", calendarTitle: "Work")
    #expect(visibility([event], rules: [rule]).occurrences == [event])
}

@Test
func anExceptionCanHideItsSeriesOnlyWithAnIdentifiableParent() throws {
    let parent = reminderEvent(local: "series", original: reminderNow.addingTimeInterval(120), recurring: true)
    let exception = reminderEvent(local: "exception", original: reminderNow.addingTimeInterval(240), detached: true)
    let rule = try hideRule(exception, scope: .series, events: [parent, exception])
    #expect(rule.localItemID == "series")
    #expect(visibility([parent, exception], rules: [rule]).occurrences.isEmpty)
    let occurrenceRule = try hideRule(exception, events: [parent, exception])
    let editedException = reminderEvent(local: "updated-exception", start: 300, end: 700, original: reminderNow.addingTimeInterval(240), detached: true)
    #expect(visibility([parent, editedException], rules: [occurrenceRule]).occurrences == [parent])
    #expect(throws: ReminderRuleError.seriesUnavailable) { try hideRule(exception, scope: .series) }
    #expect(visibility([exception], rules: [try hideRule(exception)]).occurrences.isEmpty)
}

@Test
func onlyKnownEndedMatchedOccurrenceRulesAreCleanedUp() throws {
    let event = reminderEvent()
    let rule = try hideRule(event)
    #expect(visibility([event], rules: [rule], now: event.end).retainedRules == [rule])
    #expect(visibility([event], rules: [rule], now: event.end.addingTimeInterval(1)).retainedRules.isEmpty)
    #expect(visibility([], rules: [rule], now: event.end.addingTimeInterval(86_400)).retainedRules == [rule])
    let rescheduled = reminderEvent(start: 2_000, end: 3_000)
    #expect(visibility([rescheduled], rules: [rule], now: event.end.addingTimeInterval(1)).retainedRules == [rule])
    let series = reminderEvent(local: "series", recurring: true)
    let seriesRule = try hideRule(series, scope: .series)
    #expect(visibility([series], rules: [seriesRule], now: series.end.addingTimeInterval(1)).retainedRules == [seriesRule])
}

@Test(arguments: [CountdownPhase.upcoming, CountdownPhase.ongoing])
func temporarySuppressionRestoresAtExactlySixtySeconds(phase: CountdownPhase) {
    let event = phase == .upcoming ? reminderEvent(start: 120, end: 600) : reminderEvent(start: -120, end: 120)
    let boundary = phase == .upcoming ? event.start : event.end
    let record = CountdownSuppression(occurrence: event.key, phase: phase, boundary: boundary)
    let before = visibility([event], suppressions: [record], now: reminderNow.addingTimeInterval(59.99))
    #expect(before.suppressedCountdowns == [event.key])
    #expect(before.occurrences == [event])
    let restored = visibility([event], suppressions: [record], now: reminderNow.addingTimeInterval(60))
    #expect(restored.suppressedCountdowns.isEmpty)
    #expect(restored.retainedSuppressions.isEmpty)
}

@Test
func upcomingSuppressionNeverCarriesIntoOngoing() {
    let event = reminderEvent()
    let record = CountdownSuppression(occurrence: event.key, phase: .upcoming, boundary: event.start)
    let atStart = visibility([event], suppressions: [record], now: event.start)
    #expect(atStart.retainedSuppressions.isEmpty)
    #expect(atStart.suppressedCountdowns.isEmpty)
}

@Test
func suppressionFollowsReschedulingButRestoresIfEditedIntoFinalMinute() {
    let original = reminderEvent()
    let record = CountdownSuppression(occurrence: original.key, phase: .upcoming, boundary: original.start)
    let movedLater = reminderEvent(start: 900, end: 1_800)
    let moved = visibility([movedLater], suppressions: [record], now: reminderNow.addingTimeInterval(200))
    #expect(moved.retainedSuppressions.first?.boundary == movedLater.start)
    #expect(moved.suppressedCountdowns == [movedLater.key])
    let movedSooner = reminderEvent(start: 30)
    #expect(visibility([movedSooner], suppressions: [record]).retainedSuppressions.isEmpty)
}

@Test
func absentCalendarKeepsUnexpiredSuppressionWithoutAffectingOtherEvents() {
    let target = reminderEvent()
    let other = reminderEvent(local: "other")
    let record = CountdownSuppression(occurrence: target.key, phase: .upcoming, boundary: target.start)
    let result = visibility([other], suppressions: [record])
    #expect(result.retainedSuppressions == [record])
    #expect(result.suppressedCountdowns.isEmpty)
    #expect(visibility([], suppressions: [record], now: target.start).retainedSuppressions.isEmpty)
}

@Test
func ambiguousCountdownIdentityIsLeftVisible() {
    let first = reminderEvent()
    let duplicate = reminderEvent(source: "other-source")
    let record = CountdownSuppression(occurrence: first.key, phase: .upcoming, boundary: first.start)
    #expect(visibility([first, duplicate], suppressions: [record]).suppressedCountdowns.isEmpty)
}

@MainActor
private final class ReminderMemoryStore: LocalStateStoring {
    var records: [String: Data] = [:]
    var writes = 0
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data; writes += 1 }
}

@Test @MainActor
func actionsPersistAcrossRestartAndRemainIndependent() throws {
    let storage = ReminderMemoryStore()
    let state = AppState(storage: storage)
    let reminders = ReminderRules(state: state)
    let event = reminderEvent()
    try reminders.hide(event, scope: .occurrence, calendarTitle: "Work", in: [event], at: reminderNow)
    try reminders.hide(event, scope: .occurrence, calendarTitle: "Work", in: [event], at: reminderNow)
    #expect(state.hiddenEvents.count == 1)
    try reminders.suppressCountdown(event, at: reminderNow)
    let restoredState = AppState(storage: storage)
    let restored = ReminderRules(state: restoredState)
    #expect(restored.visibility(of: [event], at: reminderNow).occurrences.isEmpty)
    try restored.unhide(try #require(restoredState.hiddenEvents.first).id)
    let result = restored.visibility(of: [event], at: reminderNow)
    #expect(result.occurrences == [event])
    #expect(result.suppressedCountdowns == [event.key])
    try restored.restoreCountdown(event.key)
    #expect(AppState(storage: storage).countdownSuppressions.isEmpty)
}

@Test @MainActor
func temporarySuppressionIsIdempotentAndFinalMinuteCannotBeHidden() throws {
    let state = AppState(storage: ReminderMemoryStore())
    let reminders = ReminderRules(state: state)
    let event = reminderEvent()
    try reminders.suppressCountdown(event, at: reminderNow)
    try reminders.suppressCountdown(event, at: reminderNow)
    #expect(state.countdownSuppressions.count == 1)
    #expect(throws: ReminderRuleError.finalMinute) { try reminders.suppressCountdown(event, at: event.start.addingTimeInterval(-60)) }
    #expect(throws: ReminderRuleError.eventEnded) { try reminders.suppressCountdown(event, at: event.end) }
    reminders.reconcile(occurrences: [event], at: event.start.addingTimeInterval(-60))
    #expect(state.countdownSuppressions.isEmpty)
    try reminders.suppressCountdown(event, at: event.start)
    #expect(state.countdownSuppressions.first?.phase == .ongoing)
}

@Test @MainActor
func unchangedReconciliationDoesNotWriteEveryTick() throws {
    let storage = ReminderMemoryStore()
    let state = AppState(storage: storage)
    let reminders = ReminderRules(state: state)
    let event = reminderEvent()
    try reminders.suppressCountdown(event, at: reminderNow)
    let before = storage.writes
    for _ in 0..<10 { reminders.reconcile(occurrences: [event], at: reminderNow) }
    #expect(storage.writes == before)
}

@Test @MainActor
func unsupportedOrAmbiguousHideActionsNeverWriteRules() {
    let state = AppState(storage: ReminderMemoryStore())
    let reminders = ReminderRules(state: state)
    let first = reminderEvent(id: "first")
    let second = reminderEvent(id: "second")
    #expect(throws: ReminderRuleError.ambiguousOccurrence) {
        try reminders.hide(first, scope: .occurrence, calendarTitle: "Work", in: [first, second], at: reminderNow)
    }
    #expect(throws: ReminderRuleError.notRecurring) {
        try reminders.hide(first, scope: .series, calendarTitle: "Work", in: [first], at: reminderNow)
    }
    let noIdentity = MeetingOccurrence(id: "unknown", calendarID: "work", title: "Unknown", start: first.start, end: first.end)
    #expect(throws: ReminderRuleError.identityUnavailable) {
        try reminders.hide(noIdentity, scope: .occurrence, calendarTitle: "Work", in: [noIdentity], at: reminderNow)
    }
    #expect(state.hiddenEvents.isEmpty)
}

@Test @MainActor
func unknownHideSchemaIsNotOverwrittenByAnAction() {
    let storage = ReminderMemoryStore()
    let newer = Data(#"{"version":99,"value":[]}"#.utf8)
    storage.records[AppStateRecord.hiddenEvents.storageKey] = newer
    let state = AppState(storage: storage)
    let reminders = ReminderRules(state: state)
    let event = reminderEvent()
    #expect(throws: AppStateError.newerRecord(.hiddenEvents)) {
        try reminders.hide(event, scope: .occurrence, calendarTitle: "Work", in: [event], at: reminderNow)
    }
    #expect(storage.records[AppStateRecord.hiddenEvents.storageKey] == newer)
    #expect(reminders.visibility(of: [event], at: reminderNow).occurrences == [event])
}

private struct ReminderFixedClock: AppClock { var now: Date { reminderNow } }

private actor ReminderCalendar: CalendarReading {
    let events: [MeetingOccurrence]
    init(event: MeetingOccurrence) { events = [event] }
    init(events: [MeetingOccurrence]) { self.events = events }
    func access() -> CalendarAccess { .fullAccess }
    func requestAccess() -> CalendarAccess { .fullAccess }
    func calendars() -> [CalendarDescriptor] { [CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Fixture")] }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) -> [MeetingOccurrence] { events }
}

@Test @MainActor
func sessionKeepsTemporarySuppressionOutOfMenuAndAudioFiltering() async throws {
    let state = AppState(storage: ReminderMemoryStore())
    try state.setSelectedCalendarIDs(["work"])
    let event = reminderEvent()
    let session = CalendarSession(reader: ReminderCalendar(event: event), state: state, clock: ReminderFixedClock())
    await session.refresh()
    let summary = session.presentation.summary
    #expect(session.presentation.hudRows.count == 1)
    try session.reminders.suppressCountdown(event, at: reminderNow)
    #expect(session.presentation.hudRows.isEmpty)
    #expect(session.presentation.summary == summary)
    #expect(session.reminderOccurrences == [event])
    try session.reminders.hide(event, scope: .occurrence, calendarTitle: "Work", in: [event], at: reminderNow)
    #expect(session.presentation.remainingToday.isEmpty)
    #expect(session.presentation.summary == .idle)
    #expect(session.reminderOccurrences.isEmpty)
    try session.reminders.unhideAll()
    #expect(session.presentation.summary == summary)
    #expect(session.presentation.hudRows.isEmpty)
}

@Test @MainActor
func temporarySuppressionNeverHidesTheWholeStack() async throws {
    let state = AppState(storage: ReminderMemoryStore())
    try state.setSelectedCalendarIDs(["work"])
    let first = reminderEvent(local: "first")
    let second = reminderEvent(local: "second", start: 180)
    let session = CalendarSession(reader: ReminderCalendar(events: [first, second]), state: state, clock: ReminderFixedClock())
    await session.refresh()
    try session.reminders.suppressCountdown(first, at: reminderNow)
    #expect(session.presentation.hudRows.map(\.id) == [second.key])
    #expect(session.reminderOccurrences == [first, second])
    #expect(session.presentation.summary == .upcoming(meetings: [first], isTomorrow: false))
}
