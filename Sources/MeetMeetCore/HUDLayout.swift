import Foundation
import CoreGraphics

public struct HUDDisplay: Equatable, Sendable {
    public let id: String
    public let workArea: CGRect

    public init(id: String, workArea: CGRect) { self.id = id; self.workArea = workArea }
}

public struct HUDLayout: Equatable, Sendable {
    public let frame: CGRect
    public let documentSize: CGSize
    public let timerWidth: Double
    public let titleWidth: Double
    public let needsScrolling: Bool
    public let displayID: String
}

public enum HUDLayoutPolicy {
    public static let rowHeight = 58.0
    public static let titleWidth = 190.0

    public static func layout(rowCount: Int, expanded: Bool, longestCountdownLength: Int,
                              preferredPosition: HUDPosition?, displays: [HUDDisplay], legacyScrollerWidth: Double = 0) -> HUDLayout? {
        let available = displays.filter(validDisplay)
        guard rowCount > 0, let primary = available.first else { return nil }
        let position = preferredPosition.flatMap { $0.isFinite ? $0 : nil }
        let display: HUDDisplay
        if let id = position?.displayID {
            display = available.first { $0.id == id } ?? primary
        } else if let anchor = position?.legacyTopRight {
            display = available.first { $0.workArea.contains(anchor) } ?? primary
        } else { display = primary }

        let area = display.workArea
        let marginX = min(24, area.width / 4)
        let marginY = min(24, area.height / 4)
        let documentHeight = Double(rowCount) * rowHeight
        let height = min(documentHeight, area.height - 2 * marginY)
        let scrolling = documentHeight > height
        let scroller = scrolling && legacyScrollerWidth.isFinite ? max(0, min(legacyScrollerWidth, area.width / 4)) : 0
        let desiredTimerWidth = max(82, Double(max(0, longestCountdownLength)) * 18)
        let desiredWidth = 28 + 23 + 12 + desiredTimerWidth + (expanded ? titleWidth + 12 : 0) + scroller
        let width = min(desiredWidth, area.width)
        let documentWidth = max(1, width - scroller)
        let timerWidth = max(1, min(desiredTimerWidth, documentWidth - 63 - (expanded ? 72 : 0)))
        let titleWidth = expanded ? max(0, min(self.titleWidth, documentWidth - timerWidth - 75)) : 0
        let right = position.map { $0.legacyTopRight?.x ?? area.maxX - $0.rightOffset } ?? area.maxX - marginX
        // Old records have no HUD height. Migrate using a single compact row.
        let bottom = position.map { $0.legacyTopRight.map { $0.y - rowHeight } ?? area.minY + $0.bottomOffset } ?? area.minY + marginY
        let x = min(max(right - width, area.minX), area.maxX - width)
        let y = min(max(bottom, area.minY), area.maxY - height)
        return HUDLayout(frame: CGRect(x: x, y: y, width: width, height: height),
                         documentSize: CGSize(width: documentWidth, height: documentHeight), timerWidth: timerWidth,
                         titleWidth: titleWidth, needsScrolling: scrolling, displayID: display.id)
    }

    public static func needsPositionRecovery(_ position: HUDPosition?, displays: [HUDDisplay]) -> Bool {
        guard let position else { return false }
        let available = displays.filter(validDisplay)
        guard position.isFinite, position.legacyTopRight == nil else { return true }
        if let id = position.displayID {
            guard let display = available.first(where: { $0.id == id }) else { return true }
            return !contains(position, in: display.workArea)
        }
        guard let primary = available.first else { return true }
        return !contains(position, in: primary.workArea)
    }

    public static func position(for frame: CGRect, displays: [HUDDisplay]) -> HUDPosition? {
        guard let id = displayID(for: frame, displays: displays),
              let display = displays.first(where: { $0.id == id }) else { return nil }
        return HUDPosition(rightOffset: display.workArea.maxX - frame.maxX,
                           bottomOffset: frame.minY - display.workArea.minY, displayID: id)
    }

    public static func displayID(for frame: CGRect, displays: [HUDDisplay]) -> String? {
        let available = displays.filter(validDisplay)
        var best = available.first
        var largestArea = 0.0
        for display in available {
            let intersection = display.workArea.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > largestArea { largestArea = area; best = display }
        }
        return best?.id
    }

    private static func validDisplay(_ display: HUDDisplay) -> Bool {
        let frame = display.workArea
        return frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite &&
            frame.maxX.isFinite && frame.maxY.isFinite && frame.width > 0 && frame.height > 0
    }

    private static func contains(_ position: HUDPosition, in frame: CGRect) -> Bool {
        position.rightOffset >= 0 && position.rightOffset <= frame.width &&
        position.bottomOffset >= 0 && position.bottomOffset <= frame.height
    }
}
