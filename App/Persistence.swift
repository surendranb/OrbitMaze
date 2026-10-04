import Foundation

/// UserDefaults-backed save data. Tiny, synchronous, main-thread only.
///
/// `mid*` fields are the lossless sleep/resume snapshot: the exact maze
/// (level + seed), ball pose and timer at the last pause/inactive/autosave.
/// The maze is deterministic from (level, seed), so these 6 numbers rebuild
/// the identical maze with the ball where it was. Absent (`midLevel == nil`)
/// means no in-progress game (home screen, win overlay, explicit quit).
struct SavedState {
    var highestLevel: Int = 1
    /// Level to offer under "Continue".
    var currentLevel: Int = 1
    var sensitivity: Sensitivity = .medium
    var invertTilt: Bool = false
    var bestTimes: [Int: Double] = [:]
    // MARK: Mid-level snapshot (nil = none)
    var midLevel: Int? = nil
    var midSeed: UInt64? = nil
    var midBallX: Double = 0
    var midBallY: Double = 0
    var midVelX: Double = 0
    var midVelY: Double = 0
    var midElapsed: Double = 0
}

enum Persistence {
    private static let highestLevelKey = "highestLevel"
    private static let currentLevelKey = "currentLevel"
    private static let sensitivityKey = "sensitivity"
    private static let invertTiltKey = "invertTilt"
    private static let bestTimesKey = "bestTimes"
    private static let midLevelKey = "midLevel"
    private static let midSeedKey = "midSeed"
    private static let midBallXKey = "midBallX"
    private static let midBallYKey = "midBallY"
    private static let midVelXKey = "midVelX"
    private static let midVelYKey = "midVelY"
    private static let midElapsedKey = "midElapsed"

    static func load(from defaults: UserDefaults = .standard) -> SavedState {
        var state = SavedState()
        state.highestLevel = max(1, defaults.integer(forKey: highestLevelKey))
        state.currentLevel = max(1, defaults.integer(forKey: currentLevelKey))
        // integer(forKey:) returns 0 (= .low) for a missing key, so check first.
        if defaults.object(forKey: sensitivityKey) != nil {
            state.sensitivity = Sensitivity(rawValue: defaults.integer(forKey: sensitivityKey)) ?? .medium
        }
        state.invertTilt = defaults.bool(forKey: invertTiltKey)
        if let raw = defaults.dictionary(forKey: bestTimesKey) as? [String: Double] {
            var times: [Int: Double] = [:]
            for (key, value) in raw {
                if let level = Int(key) { times[level] = value }
            }
            state.bestTimes = times
        }
        if defaults.object(forKey: midLevelKey) != nil {
            let lvl = defaults.integer(forKey: midLevelKey)
            if lvl >= 1, let seedString = defaults.string(forKey: midSeedKey),
               let seed = UInt64(seedString) {
                state.midLevel = lvl
                state.midSeed = seed
                state.midBallX = defaults.double(forKey: midBallXKey)
                state.midBallY = defaults.double(forKey: midBallYKey)
                state.midVelX = defaults.double(forKey: midVelXKey)
                state.midVelY = defaults.double(forKey: midVelYKey)
                state.midElapsed = max(0, defaults.double(forKey: midElapsedKey))
            }
        }
        return state
    }

    static func save(_ state: SavedState, to defaults: UserDefaults = .standard) {
        defaults.set(state.highestLevel, forKey: highestLevelKey)
        defaults.set(state.currentLevel, forKey: currentLevelKey)
        defaults.set(state.sensitivity.rawValue, forKey: sensitivityKey)
        defaults.set(state.invertTilt, forKey: invertTiltKey)
        var raw: [String: Double] = [:]
        for (level, time) in state.bestTimes { raw[String(level)] = time }
        defaults.set(raw, forKey: bestTimesKey)
        if let lvl = state.midLevel, let seed = state.midSeed {
            defaults.set(lvl, forKey: midLevelKey)
            defaults.set(String(seed), forKey: midSeedKey)
            defaults.set(state.midBallX, forKey: midBallXKey)
            defaults.set(state.midBallY, forKey: midBallYKey)
            defaults.set(state.midVelX, forKey: midVelXKey)
            defaults.set(state.midVelY, forKey: midVelYKey)
            defaults.set(state.midElapsed, forKey: midElapsedKey)
        } else {
            defaults.removeObject(forKey: midLevelKey)
            defaults.removeObject(forKey: midSeedKey)
            defaults.removeObject(forKey: midBallXKey)
            defaults.removeObject(forKey: midBallYKey)
            defaults.removeObject(forKey: midVelXKey)
            defaults.removeObject(forKey: midVelYKey)
            defaults.removeObject(forKey: midElapsedKey)
        }
    }
}
