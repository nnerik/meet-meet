import Foundation

/// Supports Google Workspace's building-floor[-section]-room resource names only.
public enum GoogleLocationShortener {
    public static func shorten(location: String) -> String {
        var text = location.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^\([^)]+\)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?:\s*\(\d+\))?(?:\s*\[[^\]]+\])?$"#,
            with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer the first floor token so a hyphen or number in the room name
        // does not become part of a greedily matched building prefix.
        // Bare level codes (LL, G, M, etc.) are valid as well as B1 and 02.
        let prefixPattern = #"^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*?-(?:(?:B|LL|M|MZ|G|P|PH)?\d+[A-Za-z]?|B|LL|MZ|G|M|P|PH|Lobby|Mezzanine|Basement|Ground)(?:-[A-Za-z0-9]{1,3})?-"#
        guard let prefix = text.range(of: prefixPattern, options: .regularExpression) else {
            return location
        }
        let room = String(text[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return room.isEmpty ? location : room
    }
}
