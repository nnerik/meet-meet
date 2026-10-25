import Foundation

/// Evidence for conservative matching, not an everlasting provider identity.
public struct EventIdentityEvidence: Equatable, Sendable {
    public let sourceID: String?
    public let localItemID: String
    public let externalItemID: String?
    public let eventID: String?
    public let originalOccurrenceDate: Date?
    public let isRecurring: Bool
    public let isDetached: Bool

    public init(sourceID: String?, localItemID: String, externalItemID: String?, eventID: String?,
                originalOccurrenceDate: Date?, isRecurring: Bool, isDetached: Bool) {
        self.sourceID = sourceID
        self.localItemID = localItemID
        self.externalItemID = externalItemID
        self.eventID = eventID
        self.originalOccurrenceDate = originalOccurrenceDate
        self.isRecurring = isRecurring
        self.isDetached = isDetached
    }

    public func occurrenceID(start: Date) -> String {
        let base = "\(localItemID.utf8.count):\(localItemID)"
        guard isRecurring || isDetached else { return base }
        let original = originalOccurrenceDate.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil } ?? start
        return base + ":" + String(original.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }
}
