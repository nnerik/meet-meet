import Foundation
import Synchronization
import Testing
@testable import MeetMeetCore

private let liveNow = Date(timeIntervalSince1970: 1_800_000_000)

private func liveCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private final class LiveClock: AppClock, Sendable {
    private let value: Mutex<Date>
    init(_ now: Date = liveNow) { value = Mutex(now) }
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}

@MainActor private final class LiveStorage: LocalStateStoring {
    private var records: [String: Data] = [:]
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data }
}

@MainActor private final class LiveRefreshScheduler: CalendarRefreshScheduling {
    var delay: TimeInterval?
    private var action: (@MainActor () async -> Void)?
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () async -> Void) {
        self.delay = delay
        self.action = action
    }
    func cancel() { delay = nil; action = nil }
    func fire() async {
        let next = action
        cancel()
        await next?()
    }
}

private actor LiveCalendarReader: CalendarReading {
    var permission = CalendarAccess.fullAccess
    var events: [MeetingOccurrence]
    var fails = false
    init(_ events: [MeetingOccurrence]) { self.events = events }
    func setEvents(_ events: [MeetingOccurrence]) { self.events = events }
    func setPermission(_ permission: CalendarAccess) { self.permission = permission }
    func setFailure(_ fails: Bool) { self.fails = fails }
    func access() -> CalendarAccess { permission }
    func requestAccess() -> CalendarAccess { permission }
    func calendars() -> [CalendarDescriptor] { [CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Fixture")] }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) throws -> [MeetingOccurrence] {
        if fails { throw CocoaError(.fileReadUnknown) }
        return events
    }
}

@MainActor private final class LiveSoundPlayer: SystemSoundPlaying {
    var sounds: [String] = []
    func play(named name: String, volume: Double) { sounds.append(name) }
}

private func liveMeeting(_ id: String = "one", start: TimeInterval, end: TimeInterval, now: Date = liveNow) -> MeetingOccurrence {
    MeetingOccurrence(id: id, calendarID: "work", title: "Meeting \(id)",
                      start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                      identityEvidence: EventIdentityEvidence(sourceID: "fixture", localItemID: id,
                                                              externalItemID: nil, eventID: id,
                                                              originalOccurrenceDate: nil, isRecurring: false, isDetached: false))
}

@MainActor private func liveState(_ storage: LiveStorage = LiveStorage()) throws -> AppState {
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["work"])
    try state.updatePreferences {
        $0.startCue.isEnabled = true
        $0.startCue.offsetMinutes = 0
        $0.endCue.isEnabled = true
        $0.endCue.offsetMinutes = 0
    }
    return state
}

@Test @MainActor func liveSessionKeepsMenuHUDAndAudioOnTheSameBoundaryTimestamp() async throws {
    let state = try liveState()
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let live = MeetingSession(reader: LiveCalendarReader([liveMeeting(start: 1, end: 3)]),
                              state: state, player: player, clock: clock, calendar: liveCalendar,
                              scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    #expect(live.presentation.hudRows.map(\.phase) == [.upcoming])
    #expect(live.menuBarState.text(titleLimit: 24, formatTime: { _ in "12:00" }) == "12:00 Meeting one")
    clock.set(liveNow.addingTimeInterval(1))
    live.tick()
    #expect(live.presentation.hudRows.map(\.phase) == [.ongoing])
    #expect(live.menuBarState.text(titleLimit: 24, formatTime: { _ in "12:00" }) == "Until 12:00 Meeting one")
    #expect(player.sounds == ["meet-meet"])
    clock.set(liveNow.addingTimeInterval(3))
    live.tick()
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.menuBarState.text(titleLimit: 24, formatTime: { _ in "12:00" }).isEmpty)
    #expect(player.sounds == ["meet-meet", "wrap-wrap"])
}

@Test @MainActor func liveSessionResumeNeverReplaysCueMissedBetweenTimerTicks() async throws {
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let live = MeetingSession(reader: LiveCalendarReader([liveMeeting(start: 2, end: 8)]),
                              state: try liveState(), player: player, clock: clock,
                              calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    try live.calendarSession.pauseForToday()
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.menuBarState == .paused)
    clock.set(liveNow.addingTimeInterval(3))
    try live.calendarSession.resume()
    live.tick()
    #expect(live.presentation.hudRows.map(\.phase) == [.ongoing])
    #expect(player.sounds.isEmpty)
}

@Test @MainActor func liveSessionSleepWakeClearsStaleRowsAndSkipsMissedCues() async throws {
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let scheduler = LiveRefreshScheduler()
    let live = MeetingSession(reader: LiveCalendarReader([liveMeeting(start: 2, end: 20)]),
                              state: try liveState(), player: player, clock: clock,
                              calendar: liveCalendar, scheduler: scheduler)
    live.start()
    defer { live.stop() }
    await live.refresh()
    live.setSleeping(true)
    clock.set(liveNow.addingTimeInterval(3))
    live.tick()
    #expect(player.sounds.isEmpty)
    live.setSleeping(false)
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.calendarSession.status == .refreshing)
    await live.refresh()
    #expect(live.presentation.hudRows.map(\.phase) == [.ongoing])
    #expect(player.sounds.isEmpty)
}

@Test @MainActor func liveSessionCalendarEditsClearStaleContentWithoutPastCueCatchUp() async throws {
    let state = try liveState()
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let reader = LiveCalendarReader([liveMeeting(start: 2, end: 20)])
    let live = MeetingSession(reader: reader, state: state, player: player, clock: clock,
                              calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    live.invalidate()
    #expect(live.presentation.hudRows.isEmpty)
    await reader.setEvents([liveMeeting(start: 1, end: 20)])
    clock.set(liveNow.addingTimeInterval(3))
    await live.refresh()
    live.tick()
    #expect(player.sounds.isEmpty)
    #expect(live.presentation.hudRows.map(\.phase) == [.ongoing])
    await reader.setEvents([liveMeeting(start: 5, end: 20)])
    live.invalidate()
    await live.refresh()
    clock.set(liveNow.addingTimeInterval(5))
    live.tick()
    #expect(player.sounds == ["meet-meet"])
}

@Test @MainActor func liveSessionPermanentHidingSuppressesAllOutputsButTemporaryHidingOnlySuppressesHUD() async throws {
    let state = try liveState()
    try state.updatePreferences { $0.startCue.offsetMinutes = 2; $0.endCue.isEnabled = false }
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let temporary = liveMeeting("temporary", start: 121, end: 600)
    let permanent = liveMeeting("permanent", start: 121, end: 600)
    let events = [temporary, permanent]
    let live = MeetingSession(reader: LiveCalendarReader(events), state: state, player: player, clock: clock,
                              calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    try live.calendarSession.reminders.suppressCountdown(temporary, at: liveNow)
    try live.calendarSession.reminders.hide(permanent, scope: .occurrence, calendarTitle: "Work", in: events, at: liveNow)
    live.tick()
    #expect(live.presentation.remainingToday.map(\.id) == ["temporary"])
    #expect(live.presentation.hudRows.isEmpty)
    clock.set(liveNow.addingTimeInterval(1))
    live.tick()
    #expect(live.presentation.hudRows.isEmpty)
    #expect(player.sounds == ["meet-meet"])
    #expect(state.handledCues.map(\.occurrence) == [temporary.key])
}

@Test @MainActor func liveSessionAccessLossRetryAndEmptyRecoveryNeverReuseStaleContent() async throws {
    let state = try liveState()
    let clock = LiveClock()
    let reader = LiveCalendarReader([liveMeeting(start: 2, end: 20)])
    let player = LiveSoundPlayer()
    let scheduler = LiveRefreshScheduler()
    let live = MeetingSession(reader: reader, state: state, player: player, clock: clock,
                              calendar: liveCalendar, scheduler: scheduler)
    live.start()
    defer { live.stop() }
    await live.refresh()
    await reader.setPermission(.denied)
    await live.calendarSession.checkAccess()
    #expect(live.calendarSession.status == .accessDenied)
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.presentation.remainingToday.isEmpty)
    #expect(live.menuBarState == .calendarIssue(.accessDenied))
    clock.set(liveNow.addingTimeInterval(3))
    live.tick()
    #expect(player.sounds.isEmpty)
    await reader.setPermission(.fullAccess)
    await live.refresh()
    #expect(live.presentation.hudRows.map(\.phase) == [.ongoing])
    #expect(player.sounds.isEmpty)
    await reader.setFailure(true)
    await live.refresh()
    #expect(live.menuBarState == .calendarIssue(.failed))
    #expect(live.presentation.hudRows.isEmpty)
    #expect(scheduler.delay == 1)
    #expect(state.selectedCalendarIDs == ["work"])
    await reader.setFailure(false)
    await reader.setEvents([])
    await scheduler.fire()
    live.tick()
    #expect(live.calendarSession.status == .ready)
    #expect(live.presentation.summary == .idle)
    #expect(live.presentation.hudRows.isEmpty)
    #expect(player.sounds.isEmpty)
}

@Test @MainActor func liveSessionMidnightKeepsOvernightBoundariesAndCoalescesShortMeetingCues() async throws {
    let calendar = liveCalendar()
    let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
    let before = midnight.addingTimeInterval(-2)
    let clock = LiveClock(before)
    let state = try liveState()
    let player = LiveSoundPlayer()
    let events = [liveMeeting("overnight", start: -30, end: 3, now: before),
                  liveMeeting("short", start: 3, end: 4, now: before)]
    let live = MeetingSession(reader: LiveCalendarReader(events), state: state, player: player, clock: clock,
                              calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    #expect(live.presentation.hudRows.count == 2)
    #expect(live.presentation.remainingToday.map(\.id) == ["overnight"])
    #expect(live.menuBarState.text(titleLimit: 24, formatTime: { _ in "00:00" }) == "Tomorrow 00:00 Meeting short")
    clock.set(midnight)
    live.tick()
    #expect(live.calendarSession.status == .refreshing)
    await live.refresh()
    let overnight = try #require(live.presentation.hudRows.first { $0.id == events[0].key })
    #expect(overnight.phase == .ongoing)
    #expect(overnight.remaining == 1)
    clock.set(midnight.addingTimeInterval(1))
    live.tick()
    #expect(live.presentation.hudRows.map(\.meeting.id) == ["short"])
    #expect(live.presentation.hudRows.map(\.phase) == [.ongoing])
    #expect(player.sounds == ["meet-meet"])
    #expect(state.handledCues.count == 2)
    clock.set(midnight.addingTimeInterval(2))
    live.tick()
    #expect(live.presentation.hudRows.isEmpty)
    #expect(player.sounds == ["meet-meet", "wrap-wrap"])
}

@Test @MainActor func liveSessionExpiredHideCleanupDoesNotDropAnotherMeetingsDueCue() async throws {
    let state = try liveState()
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let hidden = liveMeeting("hidden", start: -10, end: 0.5)
    let next = liveMeeting("next", start: 1, end: 20)
    let events = [hidden, next]
    let live = MeetingSession(reader: LiveCalendarReader(events), state: state, player: player, clock: clock,
                              calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    try live.calendarSession.reminders.hide(hidden, scope: .occurrence, calendarTitle: "Work", in: events, at: liveNow)
    live.tick()
    clock.set(liveNow.addingTimeInterval(1))
    live.tick()
    #expect(state.hiddenEvents.isEmpty)
    #expect(live.presentation.hudRows.map(\.meeting.id) == ["next"])
    #expect(player.sounds == ["meet-meet"])
    #expect(state.handledCues.map(\.occurrence) == [next.key])
}

@Test @MainActor func liveSessionRestartAndBackwardClockKeepHandledCuesSilent() async throws {
    let storage = LiveStorage()
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let events = [liveMeeting(start: 1, end: 30)]
    let first = MeetingSession(reader: LiveCalendarReader(events), state: try liveState(storage), player: player,
                               clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    first.start()
    await first.refresh()
    clock.set(liveNow.addingTimeInterval(1))
    first.tick()
    #expect(player.sounds == ["meet-meet"])
    first.stop()
    clock.set(liveNow)
    let restarted = MeetingSession(reader: LiveCalendarReader(events), state: AppState(storage: storage), player: player,
                                   clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    restarted.start()
    defer { restarted.stop() }
    await restarted.refresh()
    clock.set(liveNow.addingTimeInterval(1))
    restarted.tick()
    #expect(player.sounds == ["meet-meet"])
    clock.set(liveNow)
    restarted.tick()
    #expect(restarted.presentation.hudRows.isEmpty)
    await restarted.refresh()
    clock.set(liveNow.addingTimeInterval(1))
    restarted.tick()
    #expect(player.sounds == ["meet-meet"])
    restarted.stop()
    clock.set(liveNow.addingTimeInterval(30))
    restarted.tick()
    #expect(player.sounds == ["meet-meet"])
}

@Test @MainActor func liveSessionSettingsAndDeselectionApplyWithoutRetroactiveAudio() async throws {
    let state = try liveState()
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let live = MeetingSession(reader: LiveCalendarReader([liveMeeting(start: 2, end: 30)]),
                              state: state, player: player, clock: clock,
                              calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    try state.updatePreferences { $0.hudLeadMinutes = 0; $0.audioVolume = 0.5 }
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.menuBarState.text(titleLimit: 24, formatTime: { _ in "12:00" }) == "12:00 Meeting one")
    clock.set(liveNow.addingTimeInterval(3))
    live.tick()
    #expect(player.sounds.isEmpty)
    #expect(live.presentation.hudRows.map(\.phase) == [.ongoing])
    try state.setSelectedCalendarIDs([])
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.presentation.remainingToday.isEmpty)
    await live.refresh()
    #expect(live.menuBarState == .calendarIssue(.noCalendarsSelected))
    #expect(player.sounds.isEmpty)
}

@Test @MainActor func liveSessionSettingsReconciliationUsesFreshTimeBeforeArming() async throws {
    let state = try liveState()
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let live = MeetingSession(reader: LiveCalendarReader([liveMeeting(start: 1, end: 30)]),
                              state: state, player: player, clock: clock,
                              calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    // An edit occurs after the cue deadline but before the next native timer.
    clock.set(liveNow.addingTimeInterval(1.5))
    try state.updatePreferences { $0.audioVolume = 0.25 }
    // Deliver queued observation work without advancing the controllable clock.
    for _ in 0..<10 { await Task.yield() }
    live.tick()
    #expect(player.sounds.isEmpty)
    #expect(live.presentation.hudRows.map(\.phase) == [.ongoing])
}
