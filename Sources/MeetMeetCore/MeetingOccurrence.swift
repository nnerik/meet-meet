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

    public var meetingURL: URL? { MeetingLink.resolve(url: url, location: location) }

    /// Shared structural eligibility; boundary/time-window filtering belongs to callers.
    public var isEligibleMeeting: Bool {
        !isAllDay && !isCancelled && attendance != .declined &&
        start.timeIntervalSinceReferenceDate.isFinite && end.timeIntervalSinceReferenceDate.isFinite && end > start
    }

    public func phase(at now: Date) -> MeetingPhase {
        if now >= end { return .ended }
        return now >= start ? .ongoing : .upcoming
    }
}

public enum MeetingLink {
    /// Event URLs and location links are explicit destinations. In free-form notes,
    /// only recognize conferencing services rather than opening an unrelated link.
    public static func resolve(url: URL?, location: String?, notes: String? = nil) -> URL? {
        let explicit = url.flatMap { isSupported($0) ? $0 : nil }
        if let explicit, isConference(explicit) { return explicit }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return explicit }
        var locationURL: URL?
        for (text, requiresConference) in [(location, false), (notes, true)] {
            guard let text else { continue }
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let candidate = match.url, isSupported(candidate) else { continue }
                if isConference(candidate) { return candidate }
                if !requiresConference, locationURL == nil { locationURL = candidate }
            }
        }
        return explicit ?? locationURL
    }

    private static func isConference(_ url: URL) -> Bool {
        if ["zoommtg", "zoomus", "msteams", "webex"].contains(url.scheme?.lowercased() ?? "") { return true }
        let host = url.host?.lowercased() ?? ""
        let services = ["meet.google.com", "zoom.us", "zoom.com", "teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com", "webex.com", "whereby.com", "meet.jit.si"]
        return services.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["https", "http", "zoommtg", "zoomus", "msteams", "webex"].contains(scheme)
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
