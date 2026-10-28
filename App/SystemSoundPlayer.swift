import AppKit
import MeetMeetCore
import UniformTypeIdentifiers

/// Imports are copied into the sandbox, so moving the original file cannot break a cue.
@MainActor
enum CueMedia {
    static let prefix = "imported:"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetMeet/CueMedia", isDirectory: true)
    }

    static func url(for name: String, directory: URL = directory) -> URL? {
        guard name.hasPrefix(prefix) else { return nil }
        let filename = String(name.dropFirst(prefix.count))
        guard filename.count > 37, UUID(uuidString: String(filename.prefix(36))) != nil,
              filename.dropFirst(36).first == "-", !filename.contains("/"), !filename.contains("\\"),
              !filename.contains("\0") else { return nil }
        return directory.appendingPathComponent(filename)
    }

    static func label(for name: String) -> String {
        guard url(for: name) != nil else { return name }
        return String(name.dropFirst(prefix.count + 37))
    }

    static func choose(audio: Bool) throws -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = audio ? [.audio] : [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a cue file to copy into Meet Meet."
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        return try importFile(source, audio: audio)
    }

    static func importFile(_ source: URL, audio: Bool, directory: URL = directory) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if audio {
            guard NSSound(contentsOf: source, byReference: false) != nil else { throw ImportError.invalidAudio }
        } else {
            guard let image = NSImage(contentsOf: source), image.isValid,
                  image.size.width.isFinite, image.size.height.isFinite,
                  image.size.width > 0, image.size.height > 0 else { throw ImportError.invalidImage }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = prefix + UUID().uuidString + "-" + source.lastPathComponent
        guard let destination = url(for: name, directory: directory) else { throw ImportError.invalidName }
        try FileManager.default.copyItem(at: source, to: destination)
        return name
    }

    static func image(named name: String?, isEnd: Bool, bundle: Bundle = .main) -> NSImage? {
        let url = name.flatMap { Self.url(for: $0) } ??
            (name == nil ? bundle.url(forResource: isEnd ? "wrap-wrap" : "meet-meet", withExtension: "png") : nil)
        guard let image = url.flatMap({ NSImage(contentsOf: $0) }), image.isValid,
              image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    private enum ImportError: LocalizedError {
        case invalidAudio, invalidImage, invalidName
        var errorDescription: String? {
            switch self {
            case .invalidAudio: "This audio file cannot be played. Choose an audio format supported by macOS, such as MP3, AIFF or WAV."
            case .invalidImage: "This image cannot be read. Choose an image supported by macOS, such as PNG or JPEG."
            case .invalidName: "This file name cannot be imported. Rename the file and try again."
            }
        }
    }
}

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

    /// Resolve bundled cues, catalogued OS sounds and app-owned imports, never arbitrary paths.
    func soundURL(named name: String) -> URL? {
        if let imported = CueMedia.url(for: name) { return imported }
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
