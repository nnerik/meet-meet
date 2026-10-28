import Foundation
import Synchronization
import Testing
@testable import MeetMeetCore
#if !SWIFT_PACKAGE
import AppKit
@Test @MainActor
func nativeMeetingMenuShortensOnlyDisplayedLocationsWhenEnabled() throws {
    let raw = "US-NYC-02-D-Boardroom (16) [Google Meet, TV]"
    let event = MeetingOccurrence(id: "room", calendarID: "work", title: "Room fixture",
                                  start: pauseTestNow.addingTimeInterval(60), end: pauseTestNow.addingTimeInterval(600),
                                  location: raw, url: URL(string: "https://meet.google.com/abc-defg-hij"))
    let entry = MeetingMenuEntry(meeting: event, calendarTitle: "Work", isCountdownSuppressed: false, at: pauseTestNow)
    let original = MeetingMenuItem(entry: entry, formatTime: { _ in "START" }) { _, _ in }
    #expect(original.submenu?.items.contains { $0.title == "Location: " + raw } == true)
    let shortened = MeetingMenuItem(entry: entry, shortenGoogleRoomNames: true, formatTime: { _ in "START" }) { _, _ in }
    let location = try #require(shortened.submenu?.items.first { $0.title.hasPrefix("Location:") })
    #expect(location.title == "Location: Boardroom")
    #expect(location.toolTip == "Location: " + raw)
    #expect(entry.meeting.location == raw)
    #expect(shortened.submenu?.items.contains { $0.title == event.url?.absoluteString } == true)
}
#endif

private let pauseTestNow = Date(timeIntervalSince1970: 1_800_000_000)

private func pauseCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private final class PauseClock: AppClock, Sendable {
    private let value: Mutex<Date>
    init(now: Date = pauseTestNow) { value = Mutex(now) }
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}

@MainActor
private final class PauseStore: LocalStateStoring {
    var records: [String: Data] = [:]
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data }
}

@MainActor
private final class PauseScheduler: CalendarRefreshScheduling {
    var action: (@MainActor () async -> Void)?
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () async -> Void) { self.action = action }
    func cancel() { action = nil }
    func fire() async { let pending = action; action = nil; await pending?() }
}

private let pauseEvent = MeetingOccurrence(id: "event", calendarID: "work", title: "Team meeting", start: pauseTestNow.addingTimeInterval(120), end: pauseTestNow.addingTimeInterval(600))

private actor PauseReader: CalendarReading {
    let permission: CalendarAccess
    let events: [MeetingOccurrence]
    private(set) var fetches = 0
    init(permission: CalendarAccess = .fullAccess, events: [MeetingOccurrence] = [pauseEvent]) {
        self.permission = permission
        self.events = events
    }
    func access() -> CalendarAccess { permission }
    func requestAccess() -> CalendarAccess { permission }
    func calendars() -> [CalendarDescriptor] { [CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Fixture")] }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) -> [MeetingOccurrence] { fetches += 1; return events }
}

@MainActor
private func pauseState(storage: PauseStore = PauseStore()) throws -> AppState {
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["work"])
    return state
}

@Test @MainActor
func pauseSuppressesHUDAndAudioInputButKeepsCalendarRefreshAndMenuDetails() async throws {
    let reader = PauseReader()
    let state = try pauseState()
    let session = CalendarSession(reader: reader, state: state, clock: PauseClock(), calendar: pauseCalendar)
    await session.refresh()
    #expect(session.presentation.hudRows.count == 1)
    try session.pauseForToday()
    #expect(session.isPaused)
    #expect(session.menuBarState == .paused)
    #expect(session.presentation.hudRows.isEmpty)
    #expect(session.reminderOccurrences.isEmpty)
    #expect(session.presentation.remainingToday == [pauseEvent])
    #expect(session.meetingMenu.remainingToday.map(\.meeting) == [pauseEvent])
    #expect(state.pauseUntil == pauseCalendar().dateInterval(of: .day, for: pauseTestNow)?.end)
    await session.refresh()
    #expect(await reader.fetches == 2)
    #expect(session.occurrences == [pauseEvent])
    #expect(session.presentation.hudRows.isEmpty)
    try session.resume()
    #expect(!session.isPaused)
    #expect(state.pauseUntil == nil)
    #expect(session.presentation.hudRows.count == 1)
    #expect(session.reminderOccurrences == [pauseEvent])
    #expect(await reader.fetches == 2)
}

@Test @MainActor
func persistedPauseWinsTheTitleWhileAccessProblemsRemainAvailable() async throws {
    let storage = PauseStore()
    let state = try pauseState(storage: storage)
    try state.setPauseUntil(pauseTestNow.addingTimeInterval(600))
    let restored = AppState(storage: storage)
    let session = CalendarSession(reader: PauseReader(permission: .denied), state: restored, clock: PauseClock(), calendar: pauseCalendar)
    #expect(session.menuBarState == .paused)
    await session.refresh()
    #expect(session.status == .accessDenied)
    #expect(session.menuBarState.text(titleLimit: 24, formatTime: { _ in "unused" }) == "Paused")
    try session.resume()
    #expect(session.menuBarState == .calendarIssue(.accessDenied))
    #expect(session.menuBarState.text(titleLimit: 24, formatTime: { _ in "unused" }) == "Calendar access denied")
}

@Test @MainActor
func midnightExpirySurvivesSleepAndDoesNotReactivateAfterClockReversal() async throws {
    let storage = PauseStore()
    let state = try pauseState(storage: storage)
    let clock = PauseClock()
    let scheduler = PauseScheduler()
    let session = CalendarSession(reader: PauseReader(), state: state, clock: clock, calendar: pauseCalendar, scheduler: scheduler)
    await session.refresh()
    try session.pauseForToday()
    let expiry = try #require(state.pauseUntil)
    clock.set(expiry.addingTimeInterval(3_600))
    session.tick()
    #expect(!session.isPaused)
    #expect(state.pauseUntil == nil)
    #expect(AppState(storage: storage).pauseUntil == nil)
    await scheduler.fire()
    #expect(session.status == .ready)
    #expect(session.presentation.hudRows.isEmpty)
    clock.set(pauseTestNow)
    session.tick()
    #expect(!session.isPaused)
}

@Test @MainActor
func expiredPauseIsClearedOnLaunchEvenWithoutCalendarAccess() async throws {
    let state = try pauseState()
    try state.setPauseUntil(pauseTestNow.addingTimeInterval(-1))
    let session = CalendarSession(reader: PauseReader(permission: .notRequested), state: state, clock: PauseClock(), calendar: pauseCalendar)
    #expect(!session.isPaused)
    await session.refresh()
    #expect(state.pauseUntil == nil)
    #expect(session.status == .accessNeeded)
}

@Test(arguments: [
    ("2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23.0),
    ("2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25.0),
]) @MainActor
func pauseExpiresAtTheNextLocalMidnightAcrossDST(now: String, expiry: String, hours: Double) throws {
    let parser = ISO8601DateFormatter()
    let date = try #require(parser.date(from: now))
    let expected = try #require(parser.date(from: expiry))
    var configured = Calendar(identifier: .gregorian)
    configured.timeZone = TimeZone(identifier: "America/New_York")!
    let calendar = configured
    let state = try pauseState()
    let session = CalendarSession(reader: PauseReader(), state: state, clock: PauseClock(now: date), calendar: { calendar })
    try session.pauseForToday()
    #expect(state.pauseUntil == expected)
    #expect(expected.timeIntervalSince(date) == hours * 3_600)
}

@Test @MainActor
func pauseResumePreservesSelectionsHideRulesAndPhaseSuppression() throws {
    let state = try pauseState()
    let hidden = HiddenEventRule(scope: .series, calendarID: "work", localItemID: "series", title: "Lunch", calendarTitle: "Work")
    let suppression = CountdownSuppression(occurrence: pauseEvent.key, phase: .upcoming, boundary: pauseEvent.start)
    try state.setHiddenEvents([hidden])
    try state.setCountdownSuppressions([suppression])
    let preferences = state.preferences
    let session = CalendarSession(reader: PauseReader(), state: state, clock: PauseClock(), calendar: pauseCalendar)
    try session.pauseForToday()
    try session.resume()
    #expect(state.hiddenEvents == [hidden])
    #expect(state.countdownSuppressions == [suppression])
    #expect(state.selectedCalendarIDs == ["work"])
    #expect(state.preferences == preferences)
}

@Test @MainActor
func unknownPauseSchemaIsPreservedRatherThanOverwritten() throws {
    let storage = PauseStore()
    let newer = Data(#"{"version":99,"value":{"newData":true}}"#.utf8)
    storage.records[AppStateRecord.pause.storageKey] = newer
    let state = try pauseState(storage: storage)
    let session = CalendarSession(reader: PauseReader(), state: state, clock: PauseClock(), calendar: pauseCalendar)
    #expect(throws: AppStateError.newerRecord(.pause)) { try session.pauseForToday() }
    #expect(!session.isPaused)
    #expect(storage.records[AppStateRecord.pause.storageKey] == newer)
}

@Test
func idleAndCalendarStatusTextRemainDistinct() {
    #expect(MenuBarState.meetings(.idle).text(titleLimit: 24, formatTime: { _ in "unused" }).isEmpty)
    #expect(MenuBarState.calendarIssue(.noCalendarsSelected).text(titleLimit: 24, formatTime: { _ in "unused" }) == "Select calendars")
    #expect(MenuBarState.calendarIssue(.failed).text(titleLimit: 24, formatTime: { _ in "unused" }) == "Calendar refresh failed")
    #expect(MenuBarState.meetings(.upcoming(meetings: [pauseEvent], isTomorrow: false)).text(titleLimit: 8, formatTime: { _ in "14:00" }) == "14:00 Team mee…")
}

@Test(arguments: [
    (-60.001, CountdownPhase.upcoming, true),
    (-60.0, .upcoming, false),
    (-59.999, .upcoming, false),
    (-0.001, .upcoming, false),
    (0.0, .ongoing, true),
    (0.001, .ongoing, true),
    (419.999, .ongoing, true),
    (420.0, .ongoing, false),
    (420.001, .ongoing, false),
]) @MainActor
func meetingMenuSharesPhaseAndFinalMinuteDecisionsWithHUD(offset: TimeInterval, phase: CountdownPhase, canSuppress: Bool) async throws {
    let clock = PauseClock(now: pauseEvent.start.addingTimeInterval(offset))
    let session = CalendarSession(reader: PauseReader(), state: try pauseState(), clock: clock, calendar: pauseCalendar)
    await session.refresh()
    let entry = try #require(session.meetingMenu.remainingToday.first)
    let row = try #require(session.presentation.hudRows.first)
    #expect(entry.phase == phase)
    #expect(entry.boundary == (phase == .upcoming ? pauseEvent.start : pauseEvent.end))
    #expect(entry.countdownAction == .suppress(isEnabled: canSuppress))
    #expect(entry.phase == row.phase)
    #expect(entry.boundary == row.boundary)
    #expect(row.shouldPulse == !canSuppress)
    #expect(entry.calendarTitle == "Work")
    #expect(!entry.canHideOccurrence)
    #expect(!entry.canHideSeries)
}

@Test(arguments: [CountdownPhase.upcoming, .ongoing], [-60.001, -60.0, -59.999]) @MainActor
func meetingMenuRestoresSuppressedCountdownAtTheSameThresholdAsHUD(phase: CountdownPhase, offset: TimeInterval) async throws {
    let state = try pauseState()
    let boundary = phase == .upcoming ? pauseEvent.start : pauseEvent.end
    try state.setCountdownSuppressions([CountdownSuppression(occurrence: pauseEvent.key, phase: phase, boundary: boundary)])
    let session = CalendarSession(reader: PauseReader(), state: state, clock: PauseClock(now: boundary.addingTimeInterval(offset)), calendar: pauseCalendar)
    await session.refresh()
    let entry = try #require(session.meetingMenu.remainingToday.first)
    let suppressed = offset < -60
    #expect(entry.phase == phase)
    #expect(entry.countdownAction == (suppressed ? .restore : .suppress(isEnabled: false)))
    #expect(session.presentation.hudRows.isEmpty == suppressed)
    #expect(session.reminderOccurrences == [pauseEvent])
}

@Test @MainActor
func meetingMenuRemainsCoherentUntilSessionTimeIsReconciled() async throws {
    let state = try pauseState()
    try state.setCountdownSuppressions([CountdownSuppression(occurrence: pauseEvent.key, phase: .upcoming, boundary: pauseEvent.start)])
    let clock = PauseClock(now: pauseEvent.start.addingTimeInterval(-60.001))
    let session = CalendarSession(reader: PauseReader(), state: state, clock: clock, calendar: pauseCalendar)
    await session.refresh()
    let captured = session.meetingMenu
    #expect(captured.remainingToday.first?.countdownAction == .restore)
    clock.set(pauseEvent.start.addingTimeInterval(-59.999))
    #expect(session.meetingMenu == captured)
    #expect(session.presentation.hudRows.isEmpty)
    session.tick()
    #expect(session.meetingMenu.remainingToday.first?.countdownAction == .suppress(isEnabled: false))
    #expect(session.presentation.hudRows.count == 1)

    clock.set(pauseEvent.start.addingTimeInterval(-0.001))
    session.tick()
    await session.refresh()
    let upcoming = session.meetingMenu
    clock.set(pauseEvent.start)
    #expect(session.meetingMenu == upcoming)
    session.tick()
    #expect(session.meetingMenu.remainingToday.first?.phase == .ongoing)
    #expect(session.meetingMenu.remainingToday.first?.countdownAction == .suppress(isEnabled: true))
    // A captured menu remains a value snapshot even after the session advances.
    #expect(upcoming.remainingToday.first?.phase == .upcoming)
    #expect(upcoming.remainingToday.first?.countdownAction == .suppress(isEnabled: false))
}

@Test @MainActor
func meetingMenuKeepsPermanentHidingDistinctFromCountdownSuppression() async throws {
    let state = try pauseState()
    func meeting(_ id: String, recurring: Bool = false) -> MeetingOccurrence {
        MeetingOccurrence(id: id, calendarID: "work", title: id, start: pauseEvent.start, end: pauseEvent.end,
                          identityEvidence: EventIdentityEvidence(sourceID: "fixture", localItemID: id, externalItemID: nil,
                                                                  eventID: id, originalOccurrenceDate: nil,
                                                                  isRecurring: recurring, isDetached: false))
    }
    let occurrence = meeting("occurrence")
    let series = meeting("series", recurring: true)
    let suppressed = meeting("suppressed")
    let visibleSeries = meeting("visible-series", recurring: true)
    let events = [occurrence, series, suppressed, visibleSeries]
    let session = CalendarSession(reader: PauseReader(events: events), state: state, clock: PauseClock(), calendar: pauseCalendar)
    await session.refresh()
    try session.reminders.hide(occurrence, scope: .occurrence, calendarTitle: "Work", in: events, at: session.now)
    try session.reminders.hide(series, scope: .series, calendarTitle: "Work", in: events, at: session.now)
    try session.reminders.suppressCountdown(suppressed, at: session.now)
    let entries = session.meetingMenu.remainingToday
    #expect(entries.map(\.meeting) == [suppressed, visibleSeries])
    #expect(entries.first?.countdownAction == .restore)
    #expect(entries.first?.canHideOccurrence == true)
    #expect(entries.first?.canHideSeries == false)
    #expect(entries.last?.canHideSeries == true)
    #expect(session.presentation.hudRows.map(\.meeting) == [visibleSeries])
    #expect(session.reminderOccurrences == [suppressed, visibleSeries])
}

@Test @MainActor
func meetingMenuKeepsTomorrowLeadMeetingsAndClearsUnavailableOrEndedEntries() async throws {
    let dayEnd = try #require(pauseCalendar().dateInterval(of: .day, for: pauseTestNow)?.end)
    let now = dayEnd.addingTimeInterval(-120)
    let tomorrow = MeetingOccurrence(id: "tomorrow", calendarID: "work", title: "Tomorrow", start: dayEnd.addingTimeInterval(60), end: dayEnd.addingTimeInterval(600))
    let session = CalendarSession(reader: PauseReader(events: [tomorrow]), state: try pauseState(), clock: PauseClock(now: now), calendar: pauseCalendar)
    await session.refresh()
    #expect(session.meetingMenu.remainingToday.isEmpty)
    #expect(session.meetingMenu.tomorrow.map(\.meeting) == [tomorrow])
    #expect(session.meetingMenu.tomorrow.first?.countdownAction == .suppress(isEnabled: true))
    session.invalidate()
    #expect(session.meetingMenu.tomorrow.isEmpty)

    let ended = CalendarSession(reader: PauseReader(), state: try pauseState(), clock: PauseClock(now: pauseEvent.end), calendar: pauseCalendar)
    await ended.refresh()
    #expect(ended.meetingMenu.remainingToday.isEmpty)
    #expect(ended.meetingMenu.tomorrow.isEmpty)
}

#if !SWIFT_PACKAGE
@Test @MainActor
func nativeMeetingMenuRendersCapturedDecisionsAndDispatchesOccurrenceKeys() async throws {
    let state = try pauseState()
    let clock = PauseClock(now: pauseEvent.start.addingTimeInterval(-0.001))
    let session = CalendarSession(reader: PauseReader(), state: state, clock: clock, calendar: pauseCalendar)
    await session.refresh()
    let entry = try #require(session.meetingMenu.remainingToday.first)
    clock.set(pauseEvent.end.addingTimeInterval(1))
    var dispatched: MeetingReminderAction?
    var key: OccurrenceKey?
    let item = MeetingMenuItem(entry: entry, formatTime: { $0 == pauseEvent.start ? "START" : "END" }) { action, occurrence in
        dispatched = action
        key = occurrence
    }
    #expect(item.title == "START  Team meeting")
    #expect(item.accessibilityLabel()?.hasPrefix("Upcoming:") == true)
    let submenu = try #require(item.submenu)
    #expect(!submenu.autoenablesItems)
    #expect(submenu.items.contains { $0.title == "Upcoming · Work" })
    let suppress = try #require(submenu.items.first { $0.title == "Hide countdown until final minute" })
    #expect(!suppress.isEnabled)
    #expect(submenu.items.first { $0.title == "Hide this meeting" }?.isEnabled == false)
    #expect(submenu.items.first { $0.title == "Hide this series" }?.isEnabled == false)

    clock.set(pauseEvent.start)
    session.tick()
    let ongoing = try #require(session.meetingMenu.remainingToday.first)
    let ongoingItem = MeetingMenuItem(entry: ongoing, formatTime: { _ in "END" }) { action, occurrence in
        dispatched = action
        key = occurrence
    }
    #expect(ongoingItem.title == "Until END  Team meeting")
    #expect(ongoingItem.accessibilityLabel()?.hasPrefix("Ongoing:") == true)
    #expect(ongoingItem.submenu?.items.contains { $0.title == "Ongoing · Work" } == true)
    let ongoingMenu = try #require(ongoingItem.submenu)
    let ongoingSuppress = try #require(ongoingMenu.items.first { $0.title == "Hide countdown until final minute" })
    #expect(ongoingSuppress.isEnabled)
    ongoingMenu.performActionForItem(at: ongoingMenu.index(of: ongoingSuppress))
    #expect(dispatched == .suppressCountdown)
    #expect(key == pauseEvent.key)

    try session.reminders.suppressCountdown(pauseEvent, at: session.now)
    let restoredEntry = try #require(session.meetingMenu.remainingToday.first)
    let restoreItem = MeetingMenuItem(entry: restoredEntry, formatTime: { _ in "END" }) { action, occurrence in
        dispatched = action
        key = occurrence
    }
    let restoreMenu = try #require(restoreItem.submenu)
    let restore = try #require(restoreMenu.items.first { $0.title == "Show countdown now" })
    #expect(restore.isEnabled)
    restoreMenu.performActionForItem(at: restoreMenu.index(of: restore))
    #expect(dispatched == .restoreCountdown)
    #expect(key == pauseEvent.key)
}

@Test @MainActor
func nativeTomorrowMeetingMenuPreservesDetailsAndHideChoices() async throws {
    let state = try pauseState()
    let dayEnd = try #require(pauseCalendar().dateInterval(of: .day, for: pauseTestNow)?.end)
    let event = MeetingOccurrence(id: "series", calendarID: "work", title: "Recurring meeting",
                                  start: dayEnd.addingTimeInterval(60), end: dayEnd.addingTimeInterval(600),
                                  identityEvidence: EventIdentityEvidence(sourceID: "fixture", localItemID: "series", externalItemID: nil,
                                                                          eventID: "series", originalOccurrenceDate: nil,
                                                                          isRecurring: true, isDetached: false),
                                  location: "Meeting room", url: URL(string: "https://example.com/meeting"))
    let session = CalendarSession(reader: PauseReader(events: [event]), state: state,
                                  clock: PauseClock(now: dayEnd.addingTimeInterval(-120)), calendar: pauseCalendar)
    await session.refresh()
    let entry = try #require(session.meetingMenu.tomorrow.first)
    var dispatched: [MeetingReminderAction] = []
    let item = MeetingMenuItem(entry: entry, isTomorrow: true, formatTime: { _ in "START" }) { action, occurrence in
        dispatched.append(action)
        #expect(occurrence == event.key)
    }
    #expect(item.title == "Tomorrow START  Recurring meeting")
    #expect(item.toolTip == event.title)
    let submenu = try #require(item.submenu)
    #expect(submenu.items.contains { $0.title == "Location: Meeting room" })
    #expect(submenu.items.contains { $0.title == "https://example.com/meeting" })
    for title in ["Hide this meeting", "Hide this series"] {
        let action = try #require(submenu.items.first { $0.title == title })
        #expect(action.isEnabled)
        submenu.performActionForItem(at: submenu.index(of: action))
    }
    #expect(dispatched == [.hideOccurrence, .hideSeries])
}
#endif
