import Foundation

public struct AudioCuePreference: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var soundName: String
    public var offsetMinutes: Int

    public init(isEnabled: Bool = false, soundName: String, offsetMinutes: Int) {
        self.isEnabled = isEnabled
        self.soundName = soundName
        self.offsetMinutes = offsetMinutes
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var hudLeadMinutes = 30
    public var secondsThresholdMinutes = 5
    public var menuTitleLimit = 24
    public var splashCueEnabled = true
    public var splashLeadMinutes = 1
    public var startCue = AudioCuePreference(soundName: "meet-meet", offsetMinutes: 1)
    public var endCue = AudioCuePreference(soundName: "wrap-wrap", offsetMinutes: 2)
    public var audioVolume = 1.0

    public init() {}

    public var calendarFetchHorizonMinutes: Int {
        max(hudLeadMinutes, splashCueEnabled ? splashLeadMinutes : 0,
            startCue.isEnabled ? startCue.offsetMinutes : 0, endCue.isEnabled ? endCue.offsetMinutes : 0)
    }

    public func validated() throws -> Self {
        guard (0...120).contains(hudLeadMinutes) else { throw PreferenceError.hudLeadMinutes }
        guard (0...60).contains(secondsThresholdMinutes) else { throw PreferenceError.secondsThresholdMinutes }
        guard (8...80).contains(menuTitleLimit) else { throw PreferenceError.menuTitleLimit }
        guard (1...60).contains(splashLeadMinutes) else { throw PreferenceError.splashLeadMinutes }
        guard (0...60).contains(startCue.offsetMinutes) else { throw PreferenceError.startOffset }
        guard (0...60).contains(endCue.offsetMinutes) else { throw PreferenceError.endOffset }
        guard !startCue.soundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !endCue.soundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PreferenceError.soundName }
        guard audioVolume.isFinite, (0...1).contains(audioVolume) else { throw PreferenceError.audioVolume }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case hudLeadMinutes, secondsThresholdMinutes, menuTitleLimit, splashCueEnabled, splashLeadMinutes, startCue, endCue, audioVolume
    }

    /// Recover individual malformed fields without discarding valid sibling preferences.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let value = try? values.decode(Int.self, forKey: .hudLeadMinutes), (0...120).contains(value) { hudLeadMinutes = value }
        if let value = try? values.decode(Int.self, forKey: .secondsThresholdMinutes), (0...60).contains(value) { secondsThresholdMinutes = value }
        if let value = try? values.decode(Int.self, forKey: .menuTitleLimit), (8...80).contains(value) { menuTitleLimit = value }
        if let value = try? values.decode(Bool.self, forKey: .splashCueEnabled) { splashCueEnabled = value }
        if let value = try? values.decode(Int.self, forKey: .splashLeadMinutes), (1...60).contains(value) { splashLeadMinutes = value }
        if let value = try? values.decode(Double.self, forKey: .audioVolume), value.isFinite, (0...1).contains(value) { audioVolume = value }
        startCue = Self.decodeCue(from: values, key: .startCue, fallback: startCue)
        endCue = Self.decodeCue(from: values, key: .endCue, fallback: endCue)
    }

    private static func decodeCue(from values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys, fallback: AudioCuePreference) -> AudioCuePreference {
        guard let cue = try? values.nestedContainer(keyedBy: CueKeys.self, forKey: key) else { return fallback }
        var result = fallback
        if let value = try? cue.decode(Bool.self, forKey: .isEnabled) { result.isEnabled = value }
        if let value = try? cue.decode(String.self, forKey: .soundName), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.soundName = value }
        if let value = try? cue.decode(Int.self, forKey: .offsetMinutes), (0...60).contains(value) { result.offsetMinutes = value }
        return result
    }

    private enum CueKeys: String, CodingKey { case isEnabled, soundName, offsetMinutes }
}

public enum PreferenceError: Error, LocalizedError, Equatable {
    case hudLeadMinutes, secondsThresholdMinutes, menuTitleLimit, splashLeadMinutes, startOffset, endOffset, soundName, audioVolume

    public var errorDescription: String? {
        switch self {
        case .hudLeadMinutes: "HUD lead time must be between 0 and 120 minutes."
        case .secondsThresholdMinutes: "Seconds threshold must be between 0 and 60 minutes."
        case .menuTitleLimit: "Menu title length must be between 8 and 80 characters."
        case .splashLeadMinutes: "Splash lead time must be between 1 and 60 minutes."
        case .startOffset, .endOffset: "Audio offsets must be between 0 and 60 minutes."
        case .soundName: "Choose a bundled or system sound for each cue."
        case .audioVolume: "Audio volume must be between 0 and 1."
        }
    }
}
