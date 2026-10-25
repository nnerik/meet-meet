import Foundation

/// An app-owned value snapshot, never a retained EventKit object.
public struct MeetingOccurrence: Identifiable, Equatable, Sendable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date

    public init(id: String, calendarID: String, title: String, start: Date, end: Date) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
    }

    public func phase(at now: Date) -> MeetingPhase {
        if now >= end { return .ended }
        return now >= start ? .ongoing : .upcoming
    }
}

public enum MeetingPhase: String, Codable, Sendable {
    case upcoming
    case ongoing
    case ended
}
