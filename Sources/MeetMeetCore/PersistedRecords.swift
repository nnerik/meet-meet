import Foundation

public struct HUDPosition: Codable, Equatable, Sendable {
    public let topRightX: Double
    public let topRightY: Double
    public let displayID: String?

    public init(topRightX: Double, topRightY: Double, displayID: String? = nil) {
        self.topRightX = topRightX
        self.topRightY = topRightY
        self.displayID = displayID
    }
}

public struct OccurrenceKey: Codable, Equatable, Hashable, Sendable {
    public let calendarID: String
    public let occurrenceID: String

    public init(calendarID: String, occurrenceID: String) {
        self.calendarID = calendarID
        self.occurrenceID = occurrenceID
    }
}

public enum HideScope: String, Codable, Sendable { case occurrence, series }

/// Matching policy is implemented separately; these are calendar-scoped evidence,
/// not a promise that provider identifiers survive syncs or series splits.
public struct HiddenEventRule: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let scope: HideScope
    public let calendarID: String
    public let sourceID: String?
    public let localItemID: String?
    public let externalItemID: String?
    public let originalOccurrenceDate: Date?
    public let knownEnd: Date?
    public let title: String
    public let calendarTitle: String

    public init(id: UUID = UUID(), scope: HideScope, calendarID: String, sourceID: String? = nil,
                localItemID: String? = nil, externalItemID: String? = nil, originalOccurrenceDate: Date? = nil,
                knownEnd: Date? = nil, title: String, calendarTitle: String) {
        self.id = id
        self.scope = scope
        self.calendarID = calendarID
        self.sourceID = sourceID
        self.localItemID = localItemID
        self.externalItemID = externalItemID
        self.originalOccurrenceDate = originalOccurrenceDate
        self.knownEnd = knownEnd
        self.title = title
        self.calendarTitle = calendarTitle
    }
}

public enum CountdownPhase: String, Codable, Sendable { case upcoming, ongoing }

public struct CountdownSuppression: Codable, Equatable, Sendable {
    public let occurrence: OccurrenceKey
    public let phase: CountdownPhase
    public let boundary: Date

    public init(occurrence: OccurrenceKey, phase: CountdownPhase, boundary: Date) {
        self.occurrence = occurrence
        self.phase = phase
        self.boundary = boundary
    }
}

public enum AudioCueKind: String, Codable, Sendable { case start, end }

public struct HandledCue: Codable, Equatable, Sendable {
    public let occurrence: OccurrenceKey
    public let kind: AudioCueKind
    public let handledAt: Date

    public init(occurrence: OccurrenceKey, kind: AudioCueKind, handledAt: Date) {
        self.occurrence = occurrence
        self.kind = kind
        self.handledAt = handledAt
    }
}
