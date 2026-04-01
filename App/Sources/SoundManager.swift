import AppKit
import RenderEngine

@MainActor
final class SoundManager {
    private static let isEnabledDefaultsKey = "sound.enabled"
    private static let volumeDefaultsKey = "sound.volume"

    var isEnabled: Bool
    var volume: Float

    private var soundMap: [String: URL] = [:]
    private var currentSound: NSSound?
    private var lastPlayedState: String?
    private var lastPlayTime: Date = .distantPast

    init(userDefaults: UserDefaults = .standard) {
        isEnabled = userDefaults.object(forKey: Self.isEnabledDefaultsKey) as? Bool ?? false

        if userDefaults.object(forKey: Self.volumeDefaultsKey) != nil {
            volume = min(max(userDefaults.float(forKey: Self.volumeDefaultsKey), 0.0), 1.0)
        } else {
            volume = 0.5
        }
    }

    func loadSounds(from packDirectory: URL, manifest: SpriteManifest) {
        soundMap.removeAll()
        currentSound = nil

        guard let sounds = manifest.sounds else { return }

        for (state, relativePath) in sounds {
            let url = packDirectory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                soundMap[state] = url
            }
        }
    }

    func playSound(for state: String) {
        guard isEnabled else { return }
        guard let url = soundMap[state] else { return }

        let now = Date()
        if state == lastPlayedState && now.timeIntervalSince(lastPlayTime) < 0.5 { return }
        if currentSound?.isPlaying == true { return }

        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = volume
        sound?.play()
        currentSound = sound
        lastPlayedState = state
        lastPlayTime = now
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.isEnabledDefaultsKey)

        if !enabled {
            currentSound?.stop()
            currentSound = nil
        }
    }

    func setVolume(_ vol: Float) {
        let normalizedVolume = min(max(vol, 0.0), 1.0)
        volume = normalizedVolume
        UserDefaults.standard.set(normalizedVolume, forKey: Self.volumeDefaultsKey)
        currentSound?.volume = normalizedVolume
    }

    func applyRuntimeSettings(enabled: Bool, volume: Float) {
        isEnabled = enabled
        self.volume = min(max(volume, 0.0), 1.0)

        if !enabled {
            currentSound?.stop()
            currentSound = nil
        } else {
            currentSound?.volume = self.volume
        }
    }
}
