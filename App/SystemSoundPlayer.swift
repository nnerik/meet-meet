import AppKit
import MeetMeetCore

@MainActor
final class SystemSoundPlayer: NSObject, SystemSoundPlaying, NSSoundDelegate {
    static let bundledSoundNames = ["meet-meet", "wrap-wrap"]

    static var soundNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return bundledSoundNames + files.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    private var playing: [NSSound] = []
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        super.init()
    }

    /// Resolve only app-bundled cues and catalogued OS sounds, never arbitrary paths.
    func soundURL(named name: String) -> URL? {
        if Self.bundledSoundNames.contains(name) {
            return bundle.url(forResource: name, withExtension: "mp3")
        }
        guard Self.soundNames.contains(name) else { return nil }
        return URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
    }

    func play(named name: String, volume: Double) throws {
        guard volume.isFinite, (0...1).contains(volume), let url = soundURL(named: name),
              let sound = NSSound(contentsOf: url, byReference: false) else {
            throw SoundError.unavailable
        }
        sound.volume = Float(volume)
        sound.delegate = self
        guard sound.play() else { throw SoundError.unavailable }
        playing.append(sound)
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        playing.removeAll { $0 === sound }
    }

    private enum SoundError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The selected sound is unavailable or playback could not start." }
    }
}
