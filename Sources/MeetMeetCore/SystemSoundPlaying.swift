/// Scheduling policy decides what is due; this boundary only performs playback.
@MainActor
public protocol SystemSoundPlaying {
    func play(named name: String, volume: Double) throws
}
