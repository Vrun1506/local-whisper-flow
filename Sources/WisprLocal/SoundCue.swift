import AppKit

/// Short system sounds marking the start and end of a hold.
///
/// Audio feedback matters more than it sounds like it should: the hotkey is a
/// bare modifier with no visible effect of its own, so without a cue there's no
/// way to know a press registered before you start talking.
enum SoundCue {
    // Loaded once — NSSound(named:) hits disk, which is too slow to do on the
    // press path.
    private static let startSound = NSSound(named: "Tink")
    private static let stopSound = NSSound(named: "Pop")
    private static let errorSound = NSSound(named: "Basso")

    static func start() { play(startSound) }
    static func stop() { play(stopSound) }
    static func error() { play(errorSound) }

    private static func play(_ sound: NSSound?) {
        guard Settings.shared.playSounds, let sound else { return }
        // Rewind, or a second press during playback is silent.
        if sound.isPlaying { sound.stop() }
        sound.volume = 0.35
        sound.play()
    }
}
