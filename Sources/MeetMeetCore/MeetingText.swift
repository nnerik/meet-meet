import Foundation

public enum MeetingText {
    public static func displayLocation(_ raw: String, shortenGoogleRoomNames: Bool) -> String {
        shortenGoogleRoomNames ? GoogleLocationShortener.shorten(location: raw) : raw
    }

    public static func displayTitle(_ raw: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled meeting" : title
    }

    public static func truncatedTitle(_ raw: String, limit: Int) -> String {
        let title = displayTitle(raw)
        return title.count > max(0, limit) ? String(title.prefix(max(0, limit))) + "…" : title
    }

    public static func countdown(_ remaining: TimeInterval, secondsThresholdMinutes: Int) -> String {
        guard remaining.isFinite, remaining < Double(Int.max) else { return "—" }
        guard remaining > 0 else { return "0m" }
        if secondsThresholdMinutes > 0 && remaining < Double(secondsThresholdMinutes) * 60 {
            let seconds = Int(ceil(remaining))
            return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
        }
        let minutes = Int(ceil(remaining / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Match the visible countdown's precision/rounding without ambiguous
    /// abbreviations such as `m` (which a screen reader may read as meters).
    public static func spokenCountdown(_ remaining: TimeInterval, secondsThresholdMinutes: Int) -> String {
        guard remaining.isFinite, remaining < Double(Int.max) else { return "Time unavailable" }
        guard remaining > 0 else { return "0 minutes" }
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        if secondsThresholdMinutes > 0 && remaining < Double(secondsThresholdMinutes) * 60 {
            let seconds = Int(ceil(remaining))
            let minutes = seconds / 60
            let remainder = seconds % 60
            if minutes == 0 { return unit(remainder, "second") }
            if remainder == 0 { return unit(minutes, "minute") }
            return unit(minutes, "minute") + " " + unit(remainder, "second")
        }
        let minutes = Int(ceil(remaining / 60))
        if minutes < 60 { return unit(minutes, "minute") }
        let hours = unit(minutes / 60, "hour")
        return minutes % 60 == 0 ? hours : hours + " " + unit(minutes % 60, "minute")
    }
}
