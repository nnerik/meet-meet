import Foundation

public struct HUDRevealState: Equatable, Sendable {
    public private(set) var arrivalUntil: TimeInterval?
    private var visibleIDs: Set<OccurrenceKey> = []
    private var hovering = false

    public init() {}

    /// `now` is elapsed monotonic time, independent of calendar/clock changes.
    public mutating func update(visibleIDs next: Set<OccurrenceKey>, at now: TimeInterval) {
        if next.isEmpty {
            arrivalUntil = nil
            hovering = false
        } else if !next.subtracting(visibleIDs).isEmpty {
            arrivalUntil = now + 3
        }
        visibleIDs = next
    }

    public mutating func setHovering(_ hovering: Bool) { self.hovering = hovering && !visibleIDs.isEmpty }

    public func isExpanded(at now: TimeInterval) -> Bool {
        !visibleIDs.isEmpty && (hovering || arrivalUntil.map { now < $0 } == true)
    }
}
