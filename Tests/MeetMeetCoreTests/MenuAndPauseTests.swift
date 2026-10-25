import Foundation
import Synchronization
import Testing
@testable import MeetMeetCore

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
    private(set) var fetches = 0
    init(permission: CalendarAccess = .fullAccess) { self.permission = permission }
    func access() -> CalendarAccess { permission }
    func requestAccess() -> CalendarAccess { permission }
    func calendars() -> [CalendarDescriptor] { [CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Fixture")] }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) -> [MeetingOccurrence] { fetches += 1; return [pauseEvent] }
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
