import AppKit
import ChirpCore

/// The optional start/stop cues: stock system sounds, played quietly.
@MainActor
enum Sounds {
    private static var cache: [String: NSSound] = [:]

    static func play(_ cue: SoundCue) {
        let name = cue.systemSoundName
        guard let sound = cache[name] ?? NSSound(named: NSSound.Name(name)) else { return }
        cache[name] = sound
        sound.stop()   // a quick second tap restarts the cue instead of being swallowed
        sound.volume = 0.4
        sound.play()
    }
}
