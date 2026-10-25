import Foundation

public struct MeetingPresentation: Equatable, Sendable {
    public let remainingToday: [MeetingOccurrence]
    public let summary: MenuSummary
    public let hudRows: [CountdownRow]
}

public enum MenuSummary: Equatable, Sendable {
    case idle
    case upcoming(meetings: [MeetingOccurrence], isTomorrow: Bool)
    case ongoing(meetings: [MeetingOccurrence])

    /// Time rendering is supplied by presentation so locale and user preferences
    /// stay outside the deterministic selection policy.
    public func text(titleLimit: Int, formatTime: (Date) -> String) -> String {
        switch self {
        case .idle: return ""
        case let .upcoming(meetings, isTomorrow):
            guard let first = meetings.first else { return "" }
            let prefix = isTomorrow ? "Tomorrow " : ""
            let description = meetings.count > 1 ? "\(meetings.count) meetings" : MeetingText.truncatedTitle(first.title, limit: titleLimit)
            return "\(prefix)\(formatTime(first.start)) \(description)"
        case let .ongoing(meetings):
            guard let first = meetings.first else { return "" }
            let description = meetings.count > 1 ? "\(meetings.count) ongoing" : MeetingText.truncatedTitle(first.title, limit: titleLimit)
            return "Until \(formatTime(first.end)) \(description)"
        }
    }
}

public struct CountdownRow: Identifiable, Equatable, Sendable {
    public let meeting: MeetingOccurrence
    public let phase: CountdownPhase
    public let boundary: Date
    public let remaining: TimeInterval
    public let text: String
    public let shouldPulse: Bool

    public var id: OccurrenceKey { meeting.key }
    public var symbolName: String { phase == .upcoming ? "bell.fill" : "play.fill" }
    public var title: String { MeetingText.displayTitle(meeting.title) }
}

/// Pure snapshot policy: callers supply fresh calendar values and an explicit
/// clock reading. Permanent hiding is applied before this stage; pause, access
/// state and temporary suppression are coordinated by the application layer.
public struct MeetingPolicy: Sendable {
    private let calendar: Calendar
    private let preferences: AppPreferences

    public init(calendar: Calendar, preferences: AppPreferences) throws {
        self.calendar = calendar
        self.preferences = try preferences.validated()
    }

    public func presentation(for occurrences: [MeetingOccurrence], selectedCalendarIDs: Set<String>, at now: Date) -> MeetingPresentation {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let day = calendar.dateInterval(of: .day, for: now) else {
            return MeetingPresentation(remainingToday: [], summary: .idle, hudRows: [])
        }

        let eligible = occurrences.filter {
            selectedCalendarIDs.contains($0.calendarID) && $0.isEligibleMeeting && $0.end > now
        }
        let leadSeconds = Double(preferences.hudLeadMinutes) * 60
        let remainingToday = eligible.filter { $0.start < day.end && $0.end > day.start }.sorted(by: startOrder)
        let upcoming = eligible.filter {
            $0.start > now && ($0.start < day.end || (leadSeconds > 0 && $0.start.timeIntervalSince(now) <= leadSeconds))
        }.sorted(by: startOrder)
        let ongoing = eligible.filter { $0.start <= now }.sorted {
            $0.end == $1.end ? stableOrder($0, $1) : $0.end < $1.end
        }

        let summary: MenuSummary
        if let next = upcoming.first {
            summary = .upcoming(meetings: upcoming.filter { $0.start == next.start }, isTomorrow: !calendar.isDate(next.start, inSameDayAs: now))
        } else if !ongoing.isEmpty {
            summary = .ongoing(meetings: ongoing)
        } else {
            summary = .idle
        }

        let rows = eligible.compactMap { meeting -> CountdownRow? in
            let ongoing = meeting.start <= now
            if !ongoing && (leadSeconds == 0 || meeting.start.timeIntervalSince(now) > leadSeconds) { return nil }
            let boundary = ongoing ? meeting.end : meeting.start
            let remaining = boundary.timeIntervalSince(now)
            return CountdownRow(
                meeting: meeting, phase: ongoing ? .ongoing : .upcoming, boundary: boundary,
                remaining: remaining, text: MeetingText.countdown(remaining, secondsThresholdMinutes: preferences.secondsThresholdMinutes),
                shouldPulse: remaining > 0 && remaining <= 60
            )
        }.sorted { $0.boundary == $1.boundary ? stableOrder($0.meeting, $1.meeting) : $0.boundary < $1.boundary }

        return MeetingPresentation(remainingToday: remainingToday, summary: summary, hudRows: rows)
    }

    private func startOrder(_ lhs: MeetingOccurrence, _ rhs: MeetingOccurrence) -> Bool {
        lhs.start == rhs.start ? stableOrder(lhs, rhs) : lhs.start < rhs.start
    }

    private func stableOrder(_ lhs: MeetingOccurrence, _ rhs: MeetingOccurrence) -> Bool {
        lhs.calendarID == rhs.calendarID ? lhs.id < rhs.id : lhs.calendarID < rhs.calendarID
    }
}
