import Foundation

public enum CalendarFetchWindow {
    public static func interval(at now: Date, calendar: Calendar, preferences: AppPreferences) -> DateInterval? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let day = calendar.dateInterval(of: .day, for: now) else { return nil }
        let horizon = Double(preferences.calendarFetchHorizonMinutes) * 60
        // Margins retain events exactly on a lead/alert boundary, including an
        // end cue at midnight. Presentation policy still filters exact times.
        let end = max(day.end, now.addingTimeInterval(horizon)).addingTimeInterval(1)
        return DateInterval(start: day.start.addingTimeInterval(-1), end: end)
    }
}
