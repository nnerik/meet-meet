import Foundation

public struct ScheduledAudioCue: Equatable, Sendable {
    public let occurrence: OccurrenceKey
    public let kind: AudioCueKind
    public let date: Date
    public let soundName: String
}

/// Only previously armed, unchanged future cues may cross a normal clock tick.
/// Reset after any interruption before reconciling; past/new/edited cues never catch up.
public struct AudioCueScheduler: Sendable {
    private var armed: [ScheduledAudioCue] = []
    private var previous: Date?

    public init() {}

    public mutating func reset() { armed = []; previous = nil }

    public mutating func update(occurrences: [MeetingOccurrence], selectedCalendarIDs: Set<String>,
                                preferences: AppPreferences, handled: [HandledCue], at now: Date) -> [ScheduledAudioCue] {
        guard now.timeIntervalSinceReferenceDate.isFinite, (try? preferences.validated()) != nil else {
            reset()
            return []
        }
        // Ambiguous source identities cannot safely support at-most-once playback.
        let counts = Dictionary(grouping: occurrences, by: \.key)
        var candidates: [ScheduledAudioCue] = []
        for meeting in occurrences where meeting.isEligibleMeeting && selectedCalendarIDs.contains(meeting.calendarID) && counts[meeting.key]?.count == 1 {
            for kind in [AudioCueKind.start, .end] {
                let preference = kind == .start ? preferences.startCue : preferences.endCue
                guard preference.isEnabled,
                      !handled.contains(where: { $0.occurrence == meeting.key && $0.kind == kind }) else { continue }
                let boundary = kind == .start ? meeting.start : meeting.end
                let date = boundary.addingTimeInterval(-Double(preference.offsetMinutes) * 60)
                if kind == .end && date < meeting.start { continue }
                candidates.append(ScheduledAudioCue(occurrence: meeting.key, kind: kind, date: date, soundName: preference.soundName))
            }
        }
        let continuous = previous.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 5 } ?? false
        let due = continuous ? candidates.filter { cue in
            cue.date <= now && armed.contains(cue)
        } : []
        armed = candidates.filter { $0.date > now }
        previous = now
        return due.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.kind != $1.kind { return $0.kind == .start }
            if $0.occurrence.calendarID != $1.occurrence.calendarID { return $0.occurrence.calendarID < $1.occurrence.calendarID }
            return $0.occurrence.occurrenceID < $1.occurrence.occurrenceID
        }
    }
}
