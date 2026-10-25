/// Scheduling policy decides what is due; this boundary plays bundled or OS sounds.
@MainActor
public protocol SystemSoundPlaying {
    func play(named name: String, volume: Double) throws
}
