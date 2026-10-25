import Foundation

public enum MenuBarState: Equatable, Sendable {
    case paused
    case calendarIssue(CalendarLoadStatus)
    case meetings(MenuSummary)

    public func text(titleLimit: Int, formatTime: (Date) -> String) -> String {
        switch self {
        case .paused: "Paused"
        case let .calendarIssue(status): status.message
        case let .meetings(summary): summary.text(titleLimit: titleLimit, formatTime: formatTime)
        }
    }
}
