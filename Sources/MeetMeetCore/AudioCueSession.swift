import Foundation
import Observation

/// Persists receipts before asking the adapter to play. Failed playback is not retried.
@MainActor @Observable
public final class AudioCueSession {
    public private(set) var errorMessage: String?
    private let state: AppState
    private let player: any SystemSoundPlaying
    private let cueHandled: @MainActor ([ScheduledAudioCue]) -> Void
    private var scheduler = AudioCueScheduler()
    private var previousPreferences: AppPreferences?
    private var previousSelection: Set<String>?

    public init(state: AppState, player: any SystemSoundPlaying,
                cueHandled: @escaping @MainActor ([ScheduledAudioCue]) -> Void = { _ in }) {
        self.state = state
        self.player = player
        self.cueHandled = cueHandled
    }

    public func reset() { scheduler.reset() }

    public func update(occurrences: [MeetingOccurrence], isActive: Bool, at now: Date) {
        if previousPreferences != state.preferences || previousSelection != state.selectedCalendarIDs {
            reset()
            previousPreferences = state.preferences
            previousSelection = state.selectedCalendarIDs
        }
        let unsafeRecords: Set<AppStateRecord> = [.handledCues, .hiddenEvents, .pause, .selectedCalendars, .preferences]
        guard !state.recoveryNotices.contains(where: { unsafeRecords.contains($0.record) }) else {
            reset()
            errorMessage = "Automatic sounds are disabled because saved reminder records could not be read. Restore those records or use the app version that saved them; Preview is still available."
            return
        }
        guard isActive else { reset(); return }
        let due = scheduler.update(occurrences: occurrences, selectedCalendarIDs: state.selectedCalendarIDs,
                                   preferences: state.preferences, handled: state.handledCues, at: now)
        guard !due.isEmpty else { return }
        do {
            try state.setHandledCues(state.handledCues + due.map { HandledCue(occurrence: $0.occurrence, kind: $0.kind, handledAt: now) })
            cueHandled(due)
            // Coalesce each coincident group; never queue the other members.
            for date in Set(due.map(\.date)).sorted() {
                let group = due.filter { $0.date == date }
                let chosen = group.first { $0.kind == .start } ?? group[0]
                try play(named: chosen.soundName)
            }
        } catch {
            reset()
            errorMessage = "Could not play a meeting cue. \(error.localizedDescription) Choose a bundled or system sound and try Preview. Check the Mac's output and mute settings. This cue will not be retried."
        }
    }

    public func preview(named name: String) {
        do { try play(named: name) }
        catch { errorMessage = "Could not preview sound. \(error.localizedDescription) Choose another sound and check the Mac's output and mute settings." }
    }

    private func play(named name: String) throws {
        try player.play(named: name, volume: state.preferences.audioVolume)
        errorMessage = nil
    }
}
