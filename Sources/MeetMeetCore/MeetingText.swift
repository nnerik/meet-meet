import Foundation

public enum MeetingText {
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
}
