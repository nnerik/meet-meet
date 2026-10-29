import Foundation
import Synchronization
import Testing
@testable import MeetMeetCore
#if !SWIFT_PACKAGE
import AppKit
#endif

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
    private(set) var writes = 0
    init(records: [String: Data] = [:]) { self.records = records }
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data; writes += 1 }
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

@Test @MainActor func liveHUDInfoOpeningDoesNotConsumeAudioOrVisualCuesAndSurvivesStartRefresh() async throws {
    let state = try liveState()
    let event = liveMeeting(start: 120, end: 600)
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let live = MeetingSession(reader: LiveCalendarReader([event]), state: state, player: player,
                              clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    live.showMeetingInfo(for: event.key)
    #expect(live.splashCues.infoMeetings == [event])
    live.splashCues.dismiss()
    #expect(state.handledCues.isEmpty && state.dismissedSplashCues.isEmpty)
    for second in 1...60 {
        clock.set(liveNow.addingTimeInterval(Double(second)))
        live.tick()
    }
    #expect(live.splashCues.infoMeetings == [event])
    for second in 61...120 {
        clock.set(liveNow.addingTimeInterval(Double(second)))
        live.tick()
    }
    #expect(player.sounds == ["meet-meet"])
    #expect(live.splashCues.infoMeetings == [event])
    await live.refresh()
    #expect(live.splashCues.infoMeetings == [event])
    live.splashCues.dismiss()
    #expect(live.splashCues.infoMeetings.isEmpty)
    live.showMeetingInfo(for: event.key)
    #expect(live.splashCues.infoMeetings == [event])
    #expect(player.sounds == ["meet-meet"])
}

@Test @MainActor func liveMeetingInfoClicksRejectStaleHiddenPausedAndSuppressedHUDRows() async throws {
    let state = try liveState()
    try state.updatePreferences { $0.splashCueEnabled = false; $0.endSplashCueEnabled = false }
    let event = liveMeeting(start: 300, end: 900)
    let reader = LiveCalendarReader([event])
    let live = MeetingSession(reader: reader, state: state, player: LiveSoundPlayer(),
                              clock: LiveClock(), calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    live.showMeetingInfo(for: event.key)
    #expect(live.splashCues.infoMeetings == [event])
    live.splashCues.dismiss()
    try live.performReminderAction(.suppressCountdown, for: event.key)
    live.showMeetingInfo(for: event.key)
    #expect(live.splashCues.infoMeetings.isEmpty)
    try live.performReminderAction(.restoreCountdown, for: event.key)
    try live.calendarSession.pauseForToday()
    live.showMeetingInfo(for: event.key)
    #expect(live.splashCues.infoMeetings.isEmpty)
    try live.calendarSession.resume()
    try live.performReminderAction(.hideOccurrence, for: event.key)
    live.showMeetingInfo(for: event.key)
    #expect(live.splashCues.infoMeetings.isEmpty)
    await reader.setEvents([])
    await live.refresh()
    live.showMeetingInfo(for: event.key)
    #expect(live.splashCues.infoMeetings.isEmpty)
}

@Test @MainActor func liveSplashRespectsPauseAndHiddenMeetingsButNotTemporaryHUDSuppression() async throws {
    let state = try liveState()
    try state.updatePreferences { $0.hudLeadMinutes = 0; $0.splashLeadMinutes = 2 }
    let event = liveMeeting(start: 120, end: 600)
    let live = MeetingSession(reader: LiveCalendarReader([event]), state: state, player: LiveSoundPlayer(),
                              clock: LiveClock(), calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.splashCues.meetings == [event])
    try live.calendarSession.reminders.suppressCountdown(event, at: liveNow)
    live.tick()
    #expect(live.splashCues.meetings == [event])
    try live.calendarSession.pauseForToday()
    live.tick()
    #expect(live.splashCues.meetings.isEmpty)
    try live.calendarSession.resume()
    live.tick()
    #expect(live.splashCues.meetings == [event])
    try live.calendarSession.reminders.hide(event, scope: .occurrence, calendarTitle: "Work", in: [event], at: liveNow)
    live.tick()
    #expect(live.splashCues.meetings.isEmpty)
}

@Test @MainActor func liveSplashCatchesUpAfterWakeButNeverAfterMeetingStart() async throws {
    let clock = LiveClock()
    let event = liveMeeting(start: 120, end: 600)
    let live = MeetingSession(reader: LiveCalendarReader([event]), state: try liveState(), player: LiveSoundPlayer(),
                              clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    #expect(live.splashCues.meetings.isEmpty)
    live.setSleeping(true)
    clock.set(liveNow.addingTimeInterval(90))
    live.setSleeping(false)
    await live.refresh()
    #expect(live.splashCues.meetings == [event])
    clock.set(event.start)
    await live.refresh()
    #expect(live.splashCues.meetings.isEmpty)
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

@Test(arguments: [CountdownPhase.upcoming, .ongoing], [-0.001, 0.0, 0.001]) @MainActor
func reminderClicksRecheckTheFinalMinuteAfterTheMenuOpens(phase: CountdownPhase, offset: TimeInterval) async throws {
    let storage = LiveStorage()
    let state = try liveState(storage)
    let event = liveMeeting(start: 120, end: 600)
    let boundary = phase == .upcoming ? event.start : event.end
    let clock = LiveClock(boundary.addingTimeInterval(-60.002))
    let live = MeetingSession(reader: LiveCalendarReader([event]), state: state, player: LiveSoundPlayer(),
                              clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    let entry = try #require(live.calendarSession.meetingMenu.remainingToday.first)
    #expect(entry.countdownAction == .suppress(isEnabled: true))
    let writes = storage.writes
    clock.set(boundary.addingTimeInterval(-60 + offset))
    if offset < 0 {
        try live.performReminderAction(.suppressCountdown, for: entry.meeting.key)
        #expect(state.countdownSuppressions.first?.phase == phase)
        #expect(live.presentation.hudRows.isEmpty)
        #expect(live.calendarSession.meetingMenu.remainingToday.first?.countdownAction == .restore)
    } else {
        #expect(throws: ReminderRuleError.finalMinute) {
            try live.performReminderAction(.suppressCountdown, for: entry.meeting.key)
        }
        #expect(state.countdownSuppressions.isEmpty)
        #expect(storage.writes == writes)
    }
}

@Test @MainActor
func reminderClickAfterStartUsesTheOngoingPhaseWithoutSuppressingSound() async throws {
    let state = try liveState()
    let event = liveMeeting(start: 1, end: 121)
    let clock = LiveClock()
    let player = LiveSoundPlayer()
    let live = MeetingSession(reader: LiveCalendarReader([event]), state: state, player: player,
                              clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    let entry = try #require(live.calendarSession.meetingMenu.remainingToday.first)
    #expect(entry.phase == .upcoming)
    clock.set(event.start)
    try live.performReminderAction(.suppressCountdown, for: entry.meeting.key)
    #expect(state.countdownSuppressions == [CountdownSuppression(occurrence: event.key, phase: .ongoing, boundary: event.end)])
    #expect(live.calendarSession.now == event.start)
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.calendarSession.meetingMenu.remainingToday.first?.phase == .ongoing)
    #expect(live.calendarSession.meetingMenu.remainingToday.first?.countdownAction == .restore)
    #expect(player.sounds == ["meet-meet"])
}

@Test(arguments: [MeetingReminderAction.hideOccurrence, .hideSeries, .suppressCountdown, .restoreCountdown]) @MainActor
func reminderClicksResolveEditedOccurrencesAndUpdateVisibleState(action: MeetingReminderAction) async throws {
    let state = try liveState()
    let original = liveMeeting(start: 120, end: 600)
    let reader = LiveCalendarReader([original])
    let live = MeetingSession(reader: reader, state: state, player: LiveSoundPlayer(),
                              clock: LiveClock(), calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    let entry = try #require(live.calendarSession.meetingMenu.remainingToday.first)
    let edited = MeetingOccurrence(id: original.id, calendarID: "work", title: "Edited meeting",
                                   start: liveNow.addingTimeInterval(180), end: liveNow.addingTimeInterval(900),
                                   identityEvidence: EventIdentityEvidence(sourceID: "fixture", localItemID: "edited-series", externalItemID: nil,
                                                                           eventID: "edited", originalOccurrenceDate: nil,
                                                                           isRecurring: true, isDetached: false))
    await reader.setEvents([edited])
    await live.refresh()
    if action == .restoreCountdown { try live.performReminderAction(.suppressCountdown, for: edited.key) }
    try live.performReminderAction(action, for: entry.meeting.key)
    switch action {
    case .hideOccurrence, .hideSeries:
        #expect(live.presentation.remainingToday.isEmpty)
        #expect(live.calendarSession.meetingMenu.remainingToday.isEmpty)
        #expect(live.calendarSession.reminderOccurrences.isEmpty)
        let rule = try #require(state.hiddenEvents.first)
        #expect(rule.title == "Edited meeting")
        #expect(rule.localItemID == "edited-series")
        #expect(rule.calendarTitle == "Work")
        #expect(rule.scope == (action == .hideOccurrence ? .occurrence : .series))
    case .suppressCountdown:
        #expect(live.presentation.hudRows.isEmpty)
        #expect(live.presentation.remainingToday == [edited])
        #expect(live.calendarSession.reminderOccurrences == [edited])
        #expect(state.countdownSuppressions.first?.boundary == edited.start)
    case .restoreCountdown:
        #expect(state.countdownSuppressions.isEmpty)
        #expect(live.presentation.hudRows.map(\.meeting) == [edited])
        #expect(live.calendarSession.meetingMenu.remainingToday.first?.countdownAction == .suppress(isEnabled: true))
    }
}

private enum StaleReminderSnapshot: CaseIterable {
    case missing, ambiguous, deselected, ineligible, ended, refreshing, denied, failed, stopped, sleeping, invalidTime
}

@Test(arguments: [MeetingReminderAction.hideOccurrence, .hideSeries, .suppressCountdown, .restoreCountdown], StaleReminderSnapshot.allCases) @MainActor
private func staleReminderClicksNeverWriteReminderState(action: MeetingReminderAction, snapshot: StaleReminderSnapshot) async throws {
    let storage = LiveStorage()
    let state = try liveState(storage)
    let event = liveMeeting(start: 120, end: 600)
    let other = liveMeeting("other", start: 240, end: 900)
    try state.setCountdownSuppressions([CountdownSuppression(occurrence: event.key, phase: .upcoming, boundary: event.start),
                                        CountdownSuppression(occurrence: other.key, phase: .upcoming, boundary: other.start)])
    let reader = LiveCalendarReader([event, other])
    let clock = LiveClock()
    let live = MeetingSession(reader: reader, state: state, player: LiveSoundPlayer(),
                              clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    let entry = try #require(live.calendarSession.meetingMenu.remainingToday.first { $0.meeting.key == event.key })
    let expected: ReminderRuleError
    switch snapshot {
    case .missing:
        await reader.setEvents([other])
        await live.refresh()
        expected = .occurrenceUnavailable
    case .ambiguous:
        await reader.setEvents([event, event, other])
        await live.refresh()
        expected = .ambiguousOccurrence
    case .deselected:
        try state.setSelectedCalendarIDs([])
        expected = .occurrenceUnavailable
    case .ineligible:
        await reader.setEvents([MeetingOccurrence(id: event.id, calendarID: event.calendarID, title: event.title,
                                                  start: event.start, end: event.end, isCancelled: true), other])
        await live.refresh()
        expected = .occurrenceUnavailable
    case .ended:
        clock.set(event.end)
        expected = .eventEnded
    case .refreshing:
        live.invalidate()
        expected = .calendarUnavailable
    case .denied:
        await reader.setPermission(.denied)
        await live.refresh()
        expected = .calendarUnavailable
    case .failed:
        await reader.setFailure(true)
        await live.refresh()
        expected = .calendarUnavailable
    case .stopped:
        live.stop()
        expected = .calendarUnavailable
    case .sleeping:
        live.setSleeping(true)
        expected = .calendarUnavailable
    case .invalidTime:
        clock.set(Date(timeIntervalSince1970: .nan))
        expected = .invalidTime
    }
    let hidden = state.hiddenEvents
    let suppressions = state.countdownSuppressions
    let writes = storage.writes
    #expect(throws: expected) { try live.performReminderAction(action, for: entry.meeting.key) }
    #expect(state.hiddenEvents == hidden)
    #expect(state.countdownSuppressions == suppressions)
    #expect(storage.writes == writes)
    #expect(!expected.localizedDescription.isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func restoreFromAnOldMenuRemainsValidAfterItsSuppressionExpires(paused: Bool) async throws {
    let state = try liveState()
    let event = liveMeeting(start: 61, end: 600)
    let other = liveMeeting("other", start: 240, end: 900)
    let clock = LiveClock()
    let live = MeetingSession(reader: LiveCalendarReader([event, other]), state: state, player: LiveSoundPlayer(),
                              clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    try live.performReminderAction(.suppressCountdown, for: event.key)
    try live.performReminderAction(.suppressCountdown, for: other.key)
    let menu = live.calendarSession.meetingMenu
    #expect(menu.remainingToday.first?.countdownAction == .restore)
    if paused { try live.calendarSession.pauseForToday() }
    clock.set(liveNow.addingTimeInterval(1))
    try live.performReminderAction(.restoreCountdown, for: event.key)
    #expect(state.countdownSuppressions.map(\.occurrence) == [other.key])
    #expect(live.calendarSession.meetingMenu.remainingToday.first?.countdownAction == .suppress(isEnabled: false))
    #expect(live.calendarSession.isPaused == paused)
    #expect(live.presentation.hudRows.isEmpty == paused)
    // Restoring again is valid even though no suppression record remains.
    try live.performReminderAction(.restoreCountdown, for: event.key)
    #expect(state.countdownSuppressions.map(\.occurrence) == [other.key])
}

@Test(arguments: [MeetingReminderAction.hideOccurrence, .hideSeries, .suppressCountdown, .restoreCountdown]) @MainActor
func reminderClicksPropagateProtectedRecordErrorsWithoutPartialUpdates(action: MeetingReminderAction) async throws {
    let record: AppStateRecord = action == .hideOccurrence || action == .hideSeries ? .hiddenEvents : .countdownSuppressions
    let protected = Data(#"{"version":99,"value":[]}"#.utf8)
    let storage = LiveStorage(records: [record.storageKey: protected])
    let state = try liveState(storage)
    let event = MeetingOccurrence(id: "series", calendarID: "work", title: "Series", start: liveNow.addingTimeInterval(120), end: liveNow.addingTimeInterval(600),
                                  identityEvidence: EventIdentityEvidence(sourceID: "fixture", localItemID: "series", externalItemID: nil,
                                                                          eventID: "series", originalOccurrenceDate: nil,
                                                                          isRecurring: true, isDetached: false))
    let live = MeetingSession(reader: LiveCalendarReader([event]), state: state, player: LiveSoundPlayer(),
                              clock: LiveClock(), calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    let writes = storage.writes
    #expect(throws: AppStateError.newerRecord(record)) { try live.performReminderAction(action, for: event.key) }
    #expect(state.hiddenEvents.isEmpty)
    #expect(state.countdownSuppressions.isEmpty)
    #expect(storage.writes == writes)
    #expect(storage.data(forKey: record.storageKey) == protected)
}

#if !SWIFT_PACKAGE
@Test @MainActor
func nativeReminderDispatchRechecksAStaleMenuAndReturnsItsErrorForPresentation() async throws {
    let state = try liveState()
    let event = liveMeeting(start: 61, end: 600)
    let clock = LiveClock()
    let live = MeetingSession(reader: LiveCalendarReader([event]), state: state, player: LiveSoundPlayer(),
                              clock: clock, calendar: liveCalendar, scheduler: LiveRefreshScheduler())
    live.start()
    defer { live.stop() }
    await live.refresh()
    let entry = try #require(live.calendarSession.meetingMenu.remainingToday.first)
    var reportedError: (any Error)?
    var successes = 0
    let item = MeetingMenuItem(entry: entry, formatTime: { _ in "START" }) { action, key in
        do {
            try live.performReminderAction(action, for: key)
            successes += 1
        } catch { reportedError = error }
    }
    let menu = try #require(item.submenu)
    let index = try #require(menu.items.firstIndex { $0.title == "Hide countdown until final minute" })
    #expect(menu.items[index].isEnabled)
    let selector = try #require(menu.items[index].action)
    // Exercise the real native target/action without invoking NSMenu's global
    // tracking machinery alongside the suite's synthetic window-hover tests.
    let application = NSApplication.shared
    clock.set(liveNow.addingTimeInterval(1))
    #expect(application.sendAction(selector, to: menu.items[index].target, from: menu.items[index]))
    #expect(successes == 0)
    #expect(reportedError as? ReminderRuleError == .finalMinute)
    #expect(reportedError?.localizedDescription == ReminderRuleError.finalMinute.localizedDescription)
    #expect(state.countdownSuppressions.isEmpty)

    // The old enabled item can still dispatch, but current data is authoritative.
    clock.set(liveNow)
    #expect(application.sendAction(selector, to: menu.items[index].target, from: menu.items[index]))
    #expect(successes == 1)
    #expect(live.presentation.hudRows.isEmpty)
    #expect(live.calendarSession.meetingMenu.remainingToday.first?.countdownAction == .restore)
}
#endif
