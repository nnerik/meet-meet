import Foundation

public struct CalendarDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceTitle: String

    public init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

public enum CalendarAccess: Equatable, Sendable {
    case notRequested
    case fullAccess
    case denied
    case restricted
    case unreadable
}

/// The EventKit implementation will own its store and return immutable values.
/// Reading is deliberately the only capability exposed to the rest of the app.
public protocol CalendarReading: Sendable {
    func access() async -> CalendarAccess
    func requestAccess() async throws -> CalendarAccess
    func calendars() async throws -> [CalendarDescriptor]
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) async throws -> [MeetingOccurrence]
}
