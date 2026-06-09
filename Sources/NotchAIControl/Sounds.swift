import AppKit

/// Plays short system sounds on session state changes. User-toggleable.
enum NotchSound {
    private static let key = "soundsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// A session finished (Stop hook) — pleasant completion chime.
    static func finished() { play("Glass") }

    /// A session needs the user (permission / input) — attention tone.
    static func needsYou() { play("Funk") }

    private static func play(_ name: String) {
        guard enabled else { return }
        NSSound(named: name)?.play()
    }
}
