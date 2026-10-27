import Foundation
import Observation

public enum CalendarLoadStatus: Equatable, Sendable {
    case refreshing, accessNeeded, accessDenied, accessRestricted, accessUnreadable, noCalendarsSelected, ready, failed

    public var message: String {
        switch self {
        case .refreshing: "Refreshing calendars"
        case .accessNeeded: "Calendar access needed"
        case .accessDenied: "Calendar access denied"
        case .accessRestricted: "Calendar access restricted"
        case .accessUnreadable: "Full calendar access needed"
        case .noCalendarsSelected: "Select calendars"
        case .ready: "Calendars up to date"
        case .failed: "Calendar refresh failed"
        }
    }
}

@MainActor @Observable
public final class CalendarSession {
    public private(set) var status: CalendarLoadStatus = .refreshing
    public private(set) var access: CalendarAccess = .notRequested
    public private(set) var calendars: [CalendarDescriptor] = []
    public private(set) var occurrences: [MeetingOccurrence] = []
    public private(set) var now: Date
    public private(set) var retryDelay: TimeInterval?
    public private(set) var pausePersistenceError: String?
    public let reminders: ReminderRules

    private let reader: any CalendarReading
    private let state: AppState
    private let clock: any AppClock
    private let calendarProvider: @Sendable () -> Calendar
    private let scheduler: any CalendarRefreshScheduling
    private var generation = 0
    private var failures = 0
    private var observing = false
    private var observationGeneration = 0
    private var stopped = false
    private var lastCalendar: Calendar
    private var lastTick: Date?

    public init(reader: any CalendarReading, state: AppState, clock: any AppClock = SystemClock(),
                calendar: @escaping @Sendable () -> Calendar = { .current },
                scheduler: any CalendarRefreshScheduling = TaskCalendarRefreshScheduler()) {
        self.reader = reader
        self.state = state
        self.clock = clock
        self.calendarProvider = calendar
        self.scheduler = scheduler
        reminders = ReminderRules(state: state)
        now = clock.now
        lastCalendar = calendar()
    }

    public var presentation: MeetingPresentation {
        presentation(visibility: reminders.visibility(of: occurrences, at: now))
    }

    public var meetingMenu: MeetingMenuPresentation {
        let visibility = reminders.visibility(of: occurrences, at: now)
        let presentation = presentation(visibility: visibility)
        func entry(_ meeting: MeetingOccurrence) -> MeetingMenuEntry {
            MeetingMenuEntry(meeting: meeting,
                             calendarTitle: calendars.first { $0.id == meeting.calendarID }?.title ?? "Calendar",
                             isCountdownSuppressed: visibility.suppressedCountdowns.contains(meeting.key), at: now)
        }
        let tomorrow: [MeetingMenuEntry]
        if case let .upcoming(meetings, true) = presentation.summary { tomorrow = meetings.map(entry) }
        else { tomorrow = [] }
        return MeetingMenuPresentation(remainingToday: presentation.remainingToday.map(entry), tomorrow: tomorrow)
    }

    private func presentation(visibility: ReminderVisibility) -> MeetingPresentation {
        guard status == .ready,
              let policy = try? MeetingPolicy(calendar: calendarProvider(), preferences: state.preferences) else {
            return MeetingPresentation(remainingToday: [], summary: .idle, hudRows: [])
        }
        let result = policy.presentation(for: visibility.occurrences, selectedCalendarIDs: state.selectedCalendarIDs, at: now)
        return MeetingPresentation(remainingToday: result.remainingToday, summary: result.summary,
                                   hudRows: isPaused ? [] : result.hudRows.filter { !visibility.suppressedCountdowns.contains($0.id) })
    }

    public var isPaused: Bool { state.pauseUntil.map { $0 > now } ?? false }

    public var menuBarState: MenuBarState {
        if isPaused { return .paused }
        return status == .ready ? .meetings(presentation.summary) : .calendarIssue(status)
    }

    public func pauseForToday() throws {
        let current = clock.now
        guard current.timeIntervalSinceReferenceDate.isFinite,
              let day = calendarProvider().dateInterval(of: .day, for: current) else { throw CalendarSessionError.invalidTime }
        try state.setPauseUntil(day.end)
        now = current
        pausePersistenceError = nil
    }

    public func resume() throws {
        try state.setPauseUntil(nil)
        now = clock.now
        pausePersistenceError = nil
    }

    /// Audio and splash cues consume reminder-filtered values, not raw source snapshots.
    public var reminderOccurrences: [MeetingOccurrence] {
        guard status == .ready, !isPaused else { return [] }
        return reminders.visibility(of: occurrences, at: now).occurrences
    }

    public func start() {
        guard !observing else { return }
        observing = true
        stopped = false
        observationGeneration += 1
        observeSettings(observationGeneration)
        invalidate()
    }

    public func stop() {
        observing = false
        stopped = true
        observationGeneration += 1
        generation += 1
        scheduler.cancel()
    }

    /// Immediately invalidate in-flight requests, then coalesce a burst of changes.
    public func invalidate() {
        guard !stopped else { return }
        generation += 1
        occurrences = []
        status = .refreshing
        retryDelay = nil
        scheduler.schedule(after: 0.3) { [weak self] in await self?.refresh() }
    }

    public func tick() {
        let current = clock.now
        guard current.timeIntervalSinceReferenceDate.isFinite else {
            now = current
            invalidate()
            return
        }
        let calendar = calendarProvider()
        let dayChanged = !now.timeIntervalSinceReferenceDate.isFinite || !calendar.isDate(current, inSameDayAs: now)
        let zoneChanged = calendar.timeZone != lastCalendar.timeZone
        let clockJump = lastTick.map { current.timeIntervalSince($0) < 0 || current.timeIntervalSince($0) > 5 } ?? false
        now = current
        lastTick = current
        lastCalendar = calendar
        expirePauseIfNeeded()
        if dayChanged || zoneChanged || clockJump { invalidate() }
        if status == .ready { reminders.reconcile(occurrences: occurrences, at: now) }
    }

    public func checkAccess() async {
        let token = generation
        let current = await reader.access()
        guard token == generation else { return }
        if current != access { await refresh() }
    }

    public func requestAccess() async {
        generation += 1
        let token = generation
        scheduler.cancel()
        clearPresentation()
        status = .refreshing
        do {
            _ = try await reader.requestAccess()
            guard !stopped else { return }
            await refresh()
        } catch {
            guard token == generation else { return }
            status = .failed
        }
    }

    public func refresh() async {
        guard !stopped else { return }
        // This request already captures the latest selection/horizon. Retire
        // queued settings callbacks from older snapshots so they cannot clear
        // its freshly reconciled result after the request completes.
        if observing {
            observationGeneration += 1
            observeSettings(observationGeneration)
        }
        scheduler.cancel()
        generation += 1
        let token = generation
        let selected = state.selectedCalendarIDs
        let preferences = state.preferences
        now = clock.now
        expirePauseIfNeeded()
        clearPresentation()
        status = .refreshing
        retryDelay = nil

        let currentAccess = await reader.access()
        guard token == generation else { return }
        access = currentAccess
        guard currentAccess == .fullAccess else { showAccess(currentAccess); return }

        do {
            let available = try await reader.calendars()
            guard token == generation else { return }
            let accessAfterEnumeration = await reader.access()
            guard token == generation else { return }
            access = accessAfterEnumeration
            guard accessAfterEnumeration == .fullAccess else { showAccess(accessAfterEnumeration); return }
            guard selected == state.selectedCalendarIDs,
                  preferences.calendarFetchHorizonMinutes == state.preferences.calendarFetchHorizonMinutes else { invalidate(); return }
            calendars = available.sorted {
                if $0.sourceTitle != $1.sourceTitle { return $0.sourceTitle < $1.sourceTitle }
                return $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title
            }
            let effectiveSelection = selected.intersection(available.map(\.id))
            guard !effectiveSelection.isEmpty else {
                status = .noCalendarsSelected
                failures = 0
                return
            }
            guard let interval = CalendarFetchWindow.interval(at: clock.now, calendar: calendarProvider(), preferences: preferences) else {
                throw CalendarSessionError.invalidTime
            }
            let events = try await reader.occurrences(in: interval, calendarIDs: effectiveSelection)
            guard token == generation else { return }
            let latestAccess = await reader.access()
            guard token == generation else { return }
            access = latestAccess
            guard latestAccess == .fullAccess else { showAccess(latestAccess); return }
            guard selected == state.selectedCalendarIDs,
                  preferences.calendarFetchHorizonMinutes == state.preferences.calendarFetchHorizonMinutes else { invalidate(); return }
            occurrences = events
            now = clock.now
            status = .ready
            reminders.reconcile(occurrences: occurrences, at: now)
            failures = 0
        } catch {
            guard token == generation else { return }
            let latestAccess = await reader.access()
            guard token == generation else { return }
            access = latestAccess
            guard latestAccess == .fullAccess else { showAccess(latestAccess); return }
            clearPresentation()
            status = .failed
            failures += 1
            let delay = min(60, pow(2, Double(min(failures - 1, 6))))
            retryDelay = delay
            scheduler.schedule(after: delay) { [weak self] in await self?.refresh() }
        }
    }

    private func clearPresentation() { occurrences = [] }

    private func expirePauseIfNeeded() {
        guard let expiry = state.pauseUntil, expiry <= now else { return }
        do {
            try state.setPauseUntil(nil)
            pausePersistenceError = nil
        } catch { pausePersistenceError = error.localizedDescription }
    }

    private func showAccess(_ access: CalendarAccess) {
        clearPresentation()
        calendars = []
        failures = 0
        retryDelay = nil
        switch access {
        case .notRequested: status = .accessNeeded
        case .denied: status = .accessDenied
        case .restricted: status = .accessRestricted
        case .unreadable: status = .accessUnreadable
        case .fullAccess: break
        }
    }

    private func observeSettings(_ token: Int) {
        let selected = state.selectedCalendarIDs
        let horizon = state.preferences.calendarFetchHorizonMinutes
        withObservationTracking {
            _ = state.preferences
            _ = state.selectedCalendarIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing, self.observationGeneration == token else { return }
                self.observeSettings(token)
                if selected != self.state.selectedCalendarIDs || horizon != self.state.preferences.calendarFetchHorizonMinutes {
                    self.invalidate()
                }
            }
        }
    }
}

private enum CalendarSessionError: Error { case invalidTime }
