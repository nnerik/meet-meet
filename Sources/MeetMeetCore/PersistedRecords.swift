import Foundation

public struct HUDPosition: Codable, Equatable, Sendable {
    /// Distances inward from the display's usable lower-right corner, in points.
    public let rightOffset: Double
    public let bottomOffset: Double
    public let displayID: String?
    let legacyTopRight: CGPoint?

    public init(rightOffset: Double, bottomOffset: Double, displayID: String? = nil) {
        self.rightOffset = rightOffset
        self.bottomOffset = bottomOffset
        self.displayID = displayID
        legacyTopRight = nil
    }

    var isFinite: Bool {
        if let legacyTopRight { return legacyTopRight.x.isFinite && legacyTopRight.y.isFinite }
        return rightOffset.isFinite && bottomOffset.isFinite
    }

    private enum CodingKeys: String, CodingKey {
        case rightOffset, bottomOffset, displayID, topRightX, topRightY
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try values.decodeIfPresent(String.self, forKey: .displayID)
        if values.contains(.rightOffset) {
            rightOffset = try values.decode(Double.self, forKey: .rightOffset)
            bottomOffset = try values.decode(Double.self, forKey: .bottomOffset)
            legacyTopRight = nil
        } else {
            legacyTopRight = try CGPoint(x: values.decode(Double.self, forKey: .topRightX),
                                         y: values.decode(Double.self, forKey: .topRightY))
            rightOffset = 0
            bottomOffset = 0
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(displayID, forKey: .displayID)
        if let legacyTopRight {
            try values.encode(legacyTopRight.x, forKey: .topRightX)
            try values.encode(legacyTopRight.y, forKey: .topRightY)
        } else {
            try values.encode(rightOffset, forKey: .rightOffset)
            try values.encode(bottomOffset, forKey: .bottomOffset)
        }
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
