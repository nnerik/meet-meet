import Foundation

/// An app-owned value snapshot, never a retained EventKit object.
public struct MeetingOccurrence: Identifiable, Equatable, Sendable {
    /// Per-occurrence app identity; do not reuse a series-only identifier for its instances.
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let isCancelled: Bool
    public let attendance: MeetingAttendance
    public let availability: MeetingAvailability
    public let identityEvidence: EventIdentityEvidence?
    public let location: String?
    public let url: URL?

    public init(id: String, calendarID: String, title: String, start: Date, end: Date,
                isAllDay: Bool = false, isCancelled: Bool = false,
                attendance: MeetingAttendance = .notApplicable, availability: MeetingAvailability = .unspecified,
                identityEvidence: EventIdentityEvidence? = nil, location: String? = nil, url: URL? = nil) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.attendance = attendance
        self.availability = availability
        self.identityEvidence = identityEvidence
        self.location = location
        self.url = url
    }

    public var key: OccurrenceKey { OccurrenceKey(calendarID: calendarID, occurrenceID: id) }

    public func phase(at now: Date) -> MeetingPhase {
        if now >= end { return .ended }
        return now >= start ? .ongoing : .upcoming
    }
}

public enum MeetingAttendance: String, Sendable {
    case notApplicable, accepted, declined, tentative, unanswered
}

public enum MeetingAvailability: String, Sendable {
    case unspecified, busy, free, tentative, unavailable
}

public enum MeetingPhase: String, Codable, Sendable {
    case upcoming
    case ongoing
    case ended
}
