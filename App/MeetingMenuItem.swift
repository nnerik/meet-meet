import AppKit
import MeetMeetCore

/// Native rendering only: reminder decisions arrive in a reconciled entry.
@MainActor
final class MeetingMenuItem: NSMenuItem {
    private let performAction: (MeetingReminderAction, OccurrenceKey) -> Void

    init(entry: MeetingMenuEntry, isTomorrow: Bool = false, formatTime: (Date) -> String,
         performAction: @escaping (MeetingReminderAction, OccurrenceKey) -> Void) {
        self.performAction = performAction
        let event = entry.meeting
        let prefix = isTomorrow ? "Tomorrow " : entry.phase == .ongoing ? "Until " : ""
        super.init(title: "\(prefix)\(formatTime(entry.boundary))  \(MeetingText.displayTitle(event.title))", action: nil, keyEquivalent: "")
        let phase = entry.phase == .ongoing ? "Ongoing" : "Upcoming"
        setAccessibilityLabel("\(phase): \(MeetingText.displayTitle(event.title)), \(entry.calendarTitle), starts \(event.start.formatted()), ends \(event.end.formatted())")
        toolTip = MeetingText.displayTitle(event.title)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for title in [MeetingText.displayTitle(event.title), "\(phase) · \(entry.calendarTitle)",
                      "Starts: \(event.start.formatted(date: .abbreviated, time: .shortened))",
                      "Ends: \(event.end.formatted(date: .abbreviated, time: .shortened))"] {
            addLabel(title, to: menu)
        }
        if let location = event.location, !location.isEmpty { addLabel("Location: " + location, to: menu) }
        if let url = event.url { addLabel(url.absoluteString, to: menu) }
        menu.addItem(.separator())
        addAction("Hide this meeting", .hideOccurrence, enabled: entry.canHideOccurrence, key: event.key, to: menu)
        addAction("Hide this series", .hideSeries, enabled: entry.canHideSeries, key: event.key, to: menu)
        menu.addItem(.separator())
        switch entry.countdownAction {
        case .restore:
            addAction("Show countdown now", .restoreCountdown, key: event.key, to: menu)
        case let .suppress(isEnabled):
            addAction("Hide countdown until final minute", .suppressCountdown, enabled: isEnabled, key: event.key, to: menu)
        }
        submenu = menu
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addLabel(_ title: String, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = title
    }

    private func addAction(_ title: String, _ action: MeetingReminderAction, enabled: Bool = true, key: OccurrenceKey, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: #selector(dispatchReminderAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = action.rawValue
        item.representedObject = key
        item.isEnabled = enabled
    }

    @objc private func dispatchReminderAction(_ sender: NSMenuItem) {
        guard let action = MeetingReminderAction(rawValue: sender.tag),
              let key = sender.representedObject as? OccurrenceKey else { return }
        performAction(action, key)
    }
}
