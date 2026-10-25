import Foundation
import Synchronization
import Testing
@testable import MeetMeetCore

private let calendarTestNow = Date(timeIntervalSince1970: 1_800_000_000)

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private final class ManualCalendarClock: AppClock, Sendable {
    private let date = Mutex(calendarTestNow)
    var now: Date { date.withLock { $0 } }
    func set(_ next: Date) { date.withLock { $0 = next } }
}

@MainActor
private final class CalendarMemoryStore: LocalStateStoring {
    var records: [String: Data] = [:]
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data }
}

@MainActor
private final class ManualRefreshScheduler: CalendarRefreshScheduling {
    var delay: TimeInterval?
    var scheduledDelays: [TimeInterval] = []
    var onSchedule: (@MainActor () -> Void)?
    private var action: (@MainActor () async -> Void)?
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () async -> Void) {
        self.delay = delay
        scheduledDelays.append(delay)
        self.action = action
        let callback = onSchedule
        onSchedule = nil
        callback?()
    }
    func cancel() { action = nil; delay = nil }
    func fire() async {
        let next = action
        action = nil
        delay = nil
        await next?()
    }
}

private enum FixtureReadError: Error { case unavailable }

private actor SessionCalendarFixture: CalendarReading {
    var permission = CalendarAccess.fullAccess
    var available = [CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Fixture")]
    var events = [MeetingOccurrence(id: "meeting", calendarID: "work", title: "Example", start: calendarTestNow.addingTimeInterval(60), end: calendarTestNow.addingTimeInterval(600))]
    var fail = false
    var failEvents = false
    var requestFails = false
    var requestResponse = CalendarAccess.fullAccess
    var revokeAfterEnumeration = false
    var revokeAfterFetch = false
    var suspendFetch = false
    private(set) var requests = 0
    private(set) var fetches = 0
    private(set) var enumerations = 0
    private(set) var queriedIDs: Set<String> = []
    private(set) var queriedInterval: DateInterval?
    private var fetchWaiter: CheckedContinuation<Void, Never>?
    private var pendingFetch: CheckedContinuation<[MeetingOccurrence], any Error>?

    func configure(permission: CalendarAccess = .fullAccess, fail: Bool = false, failEvents: Bool = false, requestFails: Bool = false,
                   requestResponse: CalendarAccess = .fullAccess,
                   revokeAfterEnumeration: Bool = false, revokeAfterFetch: Bool = false, suspendFetch: Bool = false) {
        self.permission = permission
        self.fail = fail
        self.failEvents = failEvents
        self.requestFails = requestFails
        self.requestResponse = requestResponse
        self.revokeAfterEnumeration = revokeAfterEnumeration
        self.revokeAfterFetch = revokeAfterFetch
        self.suspendFetch = suspendFetch
    }
    func setAvailable(_ calendars: [CalendarDescriptor]) { available = calendars }
    func setEvents(_ events: [MeetingOccurrence]) { self.events = events }
    func access() -> CalendarAccess { permission }
    func requestAccess() throws -> CalendarAccess {
        requests += 1
        if requestFails { throw FixtureReadError.unavailable }
        permission = requestResponse
        return permission
    }
    func calendars() throws -> [CalendarDescriptor] {
        enumerations += 1
        if fail { throw FixtureReadError.unavailable }
        if revokeAfterEnumeration { permission = .denied }
        return available
    }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) async throws -> [MeetingOccurrence] {
        fetches += 1
        queriedIDs = calendarIDs
        queriedInterval = interval
        if fail || failEvents { throw FixtureReadError.unavailable }
        if suspendFetch {
            return try await withCheckedThrowingContinuation { continuation in
                pendingFetch = continuation
                fetchWaiter?.resume()
                fetchWaiter = nil
            }
        }
        if revokeAfterFetch { permission = .denied }
        return events
    }
    func waitForFetch() async {
        if pendingFetch != nil { return }
        await withCheckedContinuation { fetchWaiter = $0 }
    }
    func releaseFetch() {
        let pending = pendingFetch
        pendingFetch = nil
        pending?.resume(returning: events)
    }
}

@MainActor
private func calendarState(selected: Set<String> = ["work"]) throws -> AppState {
    let state = AppState(storage: CalendarMemoryStore())
    try state.setSelectedCalendarIDs(selected)
    return state
}

@Test(arguments: [
    (CalendarAccess.notRequested, CalendarLoadStatus.accessNeeded),
    (.denied, .accessDenied), (.restricted, .accessRestricted), (.unreadable, .accessUnreadable),
]) @MainActor
func unreadableAccessNeverEnumeratesOrPrompts(access: CalendarAccess, status: CalendarLoadStatus) async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(permission: access)
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.refresh()
    #expect(session.status == status)
    #expect(session.presentation.summary == .idle)
    #expect(session.occurrences.isEmpty)
    #expect(await reader.enumerations == 0)
    #expect(await reader.requests == 0)
}

@Test @MainActor
func permissionIsRequestedOnlyByExplicitAction() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(permission: .notRequested)
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.refresh()
    #expect(await reader.requests == 0)
    await session.requestAccess()
    #expect(await reader.requests == 1)
    #expect(session.status == .ready)
    #expect(session.occurrences.count == 1)
}

@Test @MainActor
func requestFailureClearsPresentationAndCanBeRetried() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(permission: .notRequested, requestFails: true)
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.requestAccess()
    #expect(session.status == .failed)
    #expect(session.occurrences.isEmpty)
    await reader.configure(permission: .notRequested)
    await session.requestAccess()
    #expect(session.status == .ready)
}

@Test @MainActor
func deniedRequestDoesNotRetryThePermissionPrompt() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(permission: .notRequested, requestResponse: .denied)
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    await session.requestAccess()
    #expect(session.status == .accessDenied)
    #expect(session.calendars.isEmpty)
    #expect(scheduler.delay == nil)
    #expect(await reader.requests == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func selectionChangesAreObservedWithoutManualRefresh() async throws {
    let reader = SessionCalendarFixture()
    let scheduler = ManualRefreshScheduler()
    let state = try calendarState()
    let session = CalendarSession(reader: reader, state: state, clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    session.start()
    await scheduler.fire()
    #expect(session.status == .ready)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        scheduler.onSchedule = { continuation.resume() }
        do { try state.setSelectedCalendarIDs([]) }
        catch { scheduler.onSchedule = nil; continuation.resume(throwing: error) }
    }
    #expect(session.status == .refreshing)
    #expect(session.occurrences.isEmpty)
    await scheduler.fire()
    #expect(session.status == .noCalendarsSelected)
    session.stop()
}

@Test @MainActor
func noSelectionDoesNotFetchOrSelectNewCalendars() async throws {
    let reader = SessionCalendarFixture()
    let state = try calendarState(selected: [])
    let session = CalendarSession(reader: reader, state: state, clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.refresh()
    #expect(session.status == .noCalendarsSelected)
    #expect(session.calendars.count == 1)
    #expect(state.selectedCalendarIDs.isEmpty)
    #expect(await reader.fetches == 0)
}

@Test @MainActor
func missingCalendarsKeepStoredSelectionForLaterRecovery() async throws {
    let reader = SessionCalendarFixture()
    await reader.setAvailable([])
    let state = try calendarState()
    let session = CalendarSession(reader: reader, state: state, clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.refresh()
    #expect(session.status == .noCalendarsSelected)
    #expect(state.selectedCalendarIDs == ["work"])
    await reader.setAvailable([CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Fixture")])
    await session.refresh()
    #expect(session.status == .ready)
}

@Test @MainActor
func authorizedEmptyResultIsReadyNotAnAccessError() async throws {
    let reader = SessionCalendarFixture()
    await reader.setEvents([])
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.refresh()
    #expect(session.status == .ready)
    #expect(session.presentation.summary == .idle)
    #expect(await reader.queriedIDs == ["work"])
}

@Test @MainActor
func accessLossClearsDataAndRestoresWithoutLosingChoices() async throws {
    let reader = SessionCalendarFixture()
    let state = try calendarState()
    let session = CalendarSession(reader: reader, state: state, clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.refresh()
    #expect(session.occurrences.count == 1)
    await reader.configure(permission: .denied)
    await session.checkAccess()
    #expect(session.status == .accessDenied)
    #expect(session.occurrences.isEmpty)
    #expect(session.calendars.isEmpty)
    #expect(session.presentation.hudRows.isEmpty)
    #expect(state.selectedCalendarIDs == ["work"])
    await reader.configure()
    await session.checkAccess()
    #expect(session.status == .ready)
    #expect(session.occurrences.count == 1)
}

@Test @MainActor
func revocationDuringEnumerationDoesNotPublishCalendars() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(revokeAfterEnumeration: true)
    let session = CalendarSession(reader: reader, state: try calendarState(selected: []), clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.refresh()
    #expect(session.status == .accessDenied)
    #expect(session.calendars.isEmpty)
    #expect(await reader.fetches == 0)
}

@Test @MainActor
func revocationDuringFetchDoesNotPublishMeetingTitles() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(revokeAfterFetch: true)
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar)
    await session.refresh()
    #expect(session.status == .accessDenied)
    #expect(session.occurrences.isEmpty)
}

@Test @MainActor
func refreshFailureClearsOldDataAndRetriesWithBoundedBackoff() async throws {
    let reader = SessionCalendarFixture()
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    await session.refresh()
    #expect(session.occurrences.count == 1)
    await reader.configure(fail: true)
    await session.refresh()
    #expect(session.status == .failed)
    #expect(session.presentation.hudRows.isEmpty)
    for _ in 0..<7 { await scheduler.fire() }
    #expect(scheduler.scheduledDelays == [1, 2, 4, 8, 16, 32, 60, 60])
    await reader.configure()
    await scheduler.fire()
    #expect(session.status == .ready)
    #expect(session.retryDelay == nil)
    await reader.configure(fail: true)
    await session.refresh()
    #expect(session.retryDelay == 1)
}

@Test @MainActor
func burstsOfInvalidationsProduceOneRefresh() async throws {
    let reader = SessionCalendarFixture()
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    for _ in 0..<10 { session.invalidate() }
    #expect(session.status == .refreshing)
    #expect(scheduler.delay == 0.3)
    #expect(await reader.fetches == 0)
    await scheduler.fire()
    #expect(await reader.fetches == 1)
    #expect(session.status == .ready)
}

@Test @MainActor
func eventFetchFailureIsNotAnAuthorizedEmptyResult() async throws {
    let reader = SessionCalendarFixture()
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    await session.refresh()
    await reader.configure(failEvents: true)
    await session.refresh()
    #expect(session.status == .failed)
    #expect(session.occurrences.isEmpty)
    #expect(session.retryDelay == 1)
    #expect(await reader.fetches == 2)
}

@Test @MainActor
func changedQuerySettingsDiscardAnInFlightResult() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(suspendFetch: true)
    let state = try calendarState()
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: state, clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    let loading = Task { await session.refresh() }
    await reader.waitForFetch()
    try state.updatePreferences { $0.hudLeadMinutes = 120 }
    await reader.releaseFetch()
    await loading.value
    #expect(session.status == .refreshing)
    #expect(session.occurrences.isEmpty)
    #expect(scheduler.delay == 0.3)
}

@Test @MainActor
func displayOnlyPreferenceChangesDoNotDiscardValidCalendarData() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(suspendFetch: true)
    let state = try calendarState()
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: state, clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    let loading = Task { await session.refresh() }
    await reader.waitForFetch()
    try state.updatePreferences { $0.menuTitleLimit = 8; $0.secondsThresholdMinutes = 0; $0.audioVolume = 0.5 }
    await reader.releaseFetch()
    await loading.value
    #expect(session.status == .ready)
    #expect(session.occurrences.count == 1)
    #expect(scheduler.delay == nil)
    #expect(session.presentation.hudRows.first?.text == "1m")
    #expect(await reader.fetches == 1)
}

@Test @MainActor
func inFlightResultIsDiscardedAfterSelectionChanges() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(suspendFetch: true)
    let state = try calendarState()
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: state, clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    let loading = Task { await session.refresh() }
    await reader.waitForFetch()
    try state.setSelectedCalendarIDs([])
    session.invalidate()
    await reader.releaseFetch()
    await loading.value
    #expect(session.occurrences.isEmpty)
    #expect(session.status == .refreshing)
    await scheduler.fire()
    #expect(session.status == .noCalendarsSelected)
}

@Test @MainActor
func stoppingCancelsPendingRefreshAndRejectsInFlightData() async throws {
    let reader = SessionCalendarFixture()
    await reader.configure(suspendFetch: true)
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: ManualCalendarClock(), calendar: utcCalendar, scheduler: scheduler)
    let loading = Task { await session.refresh() }
    await reader.waitForFetch()
    session.stop()
    await reader.releaseFetch()
    await loading.value
    session.invalidate()
    #expect(session.occurrences.isEmpty)
    #expect(scheduler.delay == nil)
}

@Test @MainActor
func tickUpdatesCountdownWithoutFetchingAndDetectsClockJumps() async throws {
    let reader = SessionCalendarFixture()
    let clock = ManualCalendarClock()
    let scheduler = ManualRefreshScheduler()
    let session = CalendarSession(reader: reader, state: try calendarState(), clock: clock, calendar: utcCalendar, scheduler: scheduler)
    await session.refresh()
    clock.set(calendarTestNow.addingTimeInterval(1))
    session.tick()
    #expect(session.presentation.hudRows.first?.remaining == 59)
    #expect(await reader.fetches == 1)
    clock.set(calendarTestNow.addingTimeInterval(-60))
    session.tick()
    #expect(session.status == .refreshing)
    #expect(scheduler.delay == 0.3)
}

@Test
func fetchWindowIncludesTodayOverlapsAndMidnightHorizons() throws {
    let now = ISO8601DateFormatter().date(from: "2026-10-25T23:58:00Z")!
    var preferences = AppPreferences()
    preferences.hudLeadMinutes = 120
    let interval = try #require(CalendarFetchWindow.interval(at: now, calendar: utcCalendar(), preferences: preferences))
    #expect(interval.start == utcCalendar().startOfDay(for: now).addingTimeInterval(-1))
    #expect(interval.end == now.addingTimeInterval(7_201))
    preferences.hudLeadMinutes = 0
    preferences.endCue.isEnabled = true
    preferences.endCue.offsetMinutes = 60
    let audio = try #require(CalendarFetchWindow.interval(at: now, calendar: utcCalendar(), preferences: preferences))
    #expect(audio.end == now.addingTimeInterval(3_601))
    preferences.endCue.isEnabled = false
    let disabled = try #require(CalendarFetchWindow.interval(at: now, calendar: utcCalendar(), preferences: preferences))
    #expect(disabled.end == utcCalendar().dateInterval(of: .day, for: now)!.end.addingTimeInterval(1))
}

@Test
func identityDistinguishesOccurrencesAndSurvivesMovedExceptions() {
    let original = calendarTestNow
    let recurring = EventIdentityEvidence(sourceID: "source", localItemID: "series", externalItemID: "external", eventID: nil, originalOccurrenceDate: original, isRecurring: true, isDetached: false)
    let moved = EventIdentityEvidence(sourceID: "source", localItemID: "series", externalItemID: "external", eventID: nil, originalOccurrenceDate: original, isRecurring: false, isDetached: true)
    #expect(recurring.occurrenceID(start: original) == moved.occurrenceID(start: original.addingTimeInterval(600)))
    let next = EventIdentityEvidence(sourceID: "source", localItemID: "series", externalItemID: "external", eventID: nil, originalOccurrenceDate: original.addingTimeInterval(86_400), isRecurring: true, isDetached: false)
    #expect(next.occurrenceID(start: original) != recurring.occurrenceID(start: original))
    let standalone = EventIdentityEvidence(sourceID: nil, localItemID: "single", externalItemID: nil, eventID: nil, originalOccurrenceDate: nil, isRecurring: false, isDetached: false)
    #expect(standalone.occurrenceID(start: original) == standalone.occurrenceID(start: original.addingTimeInterval(600)))
}

@Test(arguments: [("2026-03-08T12:00:00Z", 23.0), ("2026-11-01T12:00:00Z", 25.0)])
func fetchWindowUsesCalendarDaysNotFixedDurations(now: String, hours: Double) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let date = ISO8601DateFormatter().date(from: now)!
    let interval = try #require(CalendarFetchWindow.interval(at: date, calendar: calendar, preferences: AppPreferences()))
    #expect(interval.duration == hours * 3_600 + 2)
}
