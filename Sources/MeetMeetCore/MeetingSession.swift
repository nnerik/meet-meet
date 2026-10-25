import Foundation
import Observation

/// Shared live pipeline. Menu, HUD and audio use the same reconciled calendar
/// values and timestamp; native callers supply only lifecycle events and adapters.
@MainActor
public final class MeetingSession {
    public let calendarSession: CalendarSession
    public let audioCues: AudioCueSession
    private let state: AppState
    private var running = false
    private var observationGeneration = 0
    private var observationPending = false
    private var sleeping = false
    private var advancingTime = false

    public var presentation: MeetingPresentation { calendarSession.presentation }
    public var menuBarState: MenuBarState { calendarSession.menuBarState }

    public init(reader: any CalendarReading, state: AppState, player: any SystemSoundPlaying,
                clock: any AppClock = SystemClock(), calendar: @escaping @Sendable () -> Calendar = { .current },
                scheduler: any CalendarRefreshScheduling = TaskCalendarRefreshScheduler(),
                cueHandled: @escaping @MainActor ([ScheduledAudioCue]) -> Void = { _ in }) {
        self.state = state
        calendarSession = CalendarSession(reader: reader, state: state, clock: clock, calendar: calendar, scheduler: scheduler)
        audioCues = AudioCueSession(state: state, player: player, cueHandled: cueHandled)
    }

    public func start() {
        guard !running else { return }
        running = true
        calendarSession.start()
        renewObservation()
    }

    public func stop() {
        running = false
        observationGeneration += 1
        audioCues.reset()
        calendarSession.stop()
    }

    public func refresh() async {
        audioCues.reset()
        await calendarSession.refresh()
        if running { renewObservation() }
    }

    public func tick() {
        guard running, !sleeping else { return }
        advancingTime = true
        calendarSession.tick()
        advancingTime = false
        if observationPending { renewObservation() }
        else { updateAudio() }
    }

    public func setSleeping(_ sleeping: Bool) {
        self.sleeping = sleeping
        audioCues.reset()
        if !sleeping { calendarSession.invalidate() }
    }

    public func invalidate() {
        audioCues.reset()
        calendarSession.invalidate()
    }

    private func updateAudio() {
        guard running, !sleeping, !observationPending else { return }
        audioCues.update(occurrences: calendarSession.reminderOccurrences,
                         isActive: calendarSession.status == .ready && !calendarSession.isPaused,
                         at: calendarSession.now)
    }

    private func renewObservation() {
        observationGeneration += 1
        observationPending = false
        observe(observationGeneration)
    }

    private func observe(_ token: Int) {
        withObservationTracking {
            _ = state.preferences
            _ = state.selectedCalendarIDs
            _ = state.pauseUntil
            _ = state.hiddenEvents
            _ = calendarSession.status
            _ = calendarSession.occurrences
        } onChange: { [weak self] in
            // These values are main-actor owned. Disarm before any queued tick
            // can cross a deadline using settings/snapshots that are changing.
            MainActor.assumeIsolated {
                guard let self, self.running, self.observationGeneration == token else { return }
                self.observationPending = true
                // Timestamp reconciliation may expire a different meeting's
                // hide rule. Preserve armed eligible cues through that cleanup;
                // clock/access invalidation still resets via inactive input.
                if !self.advancingTime { self.audioCues.reset() }
            }
            Task { @MainActor in
                guard let self, self.running, self.observationGeneration == token else { return }
                // Settings can change between native ticks, after a deadline.
                // Refresh the shared timestamp before arming, never from the
                // previous timer's stale time (which could rearm a missed cue).
                self.tick()
            }
        }
        updateAudio()
    }
}
