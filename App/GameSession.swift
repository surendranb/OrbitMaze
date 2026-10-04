import Foundation
import Observation
import WatchKit

/// Screen-level coordinator: owns the pure `GameModel`, the tilt source, the
/// frame loop, haptics and persistence. Everything runs on the main actor.
///
/// Observation strategy: the model is mutated 60× per second, so it is kept
/// out of observation (`@ObservationIgnored`) and a handful of cheap display
/// fields (`phase`, `level`, `elapsedTenths`, …) are mirrored only when they
/// change. The maze canvas re-renders from `renderFrame()` on every
/// TimelineView tick regardless.
///
/// Screen wake: watchOS has no equivalent of `isIdleTimerDisabled`. The
/// display turns off on wrist-down and after the user's Wake Duration
/// (Settings › Display & Brightness › Wake Duration: 15 s or 70 s) with no
/// touch or crown input; tilt alone does not reset that timer.
/// WKExtendedRuntimeSession is limited to self-care, mindfulness, physical
/// therapy and smart-alarm sessions and does not keep the screen on, so a
/// game may not use it. The app therefore pauses when the scene leaves
/// `.active`, persists the exact mid-level snapshot (level + seed + ball +
/// timer) to UserDefaults, and resumes through a 1 s countdown (3 s after a
/// cold restore, which recaptures tilt neutral); README tells users to pick
/// the 70 s wake duration and to tap the screen (single taps never pause)
/// before it expires.
@MainActor
@Observable
final class GameSession {
    enum Screen: Equatable { case home, game }

    // MARK: Observed display state

    private(set) var screen: Screen = .home
    private(set) var phase: GamePhase = .calibrating
    private(set) var level: Int = 1
    private(set) var highestLevel: Int = 1
    private(set) var elapsedTenths: Int = 0
    /// Level offered by "Continue" on the Home screen.
    private(set) var savedLevel: Int = 1
    private(set) var isNewBest = false

    private(set) var sensitivity: Sensitivity
    private(set) var invertTilt: Bool

    let tilt: TiltController

    func setSensitivity(_ s: Sensitivity) {
        guard s != sensitivity else { return }
        sensitivity = s
        model.setSensitivity(s)
        tilt.apply(sensitivity: s)
        syncDisplayState()
        persist()
    }

    func setInvertTilt(_ on: Bool) {
        guard on != invertTilt else { return }
        invertTilt = on
        tilt.apply(invert: on)
        persist()
    }

    // MARK: Hot-path state (not observed)

    @ObservationIgnored private(set) var model: GameModel
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var trail: [Vec2] = []
    @ObservationIgnored private var trailHead = 0
    @ObservationIgnored private var lastClickTime: TimeInterval = -1
    @ObservationIgnored private var frameClock: TimeInterval = 0
    /// Throttle for mid-level autosaves during play (UserDefaults is sync I/O).
    @ObservationIgnored private var lastMidSaveClock: TimeInterval = 0
    /// Fired once per level at 55 s of play to prompt a wake-keeping tap.
    @ObservationIgnored private var wakeNudgeShown = false

    private static let trailLength = 18
    private static let clickMinImpact = 0.3
    private static let clickMinGap = 0.12
    private static let maxFrameDelta = 0.1
    private static let midSaveInterval: TimeInterval = 5
    private static let wakeNudgeElapsed: Double = 55

    // MARK: Init

    init() {
        let saved = Persistence.load()
        sensitivity = saved.sensitivity
        invertTilt = saved.invertTilt
        highestLevel = saved.highestLevel
        tilt = TiltController(sensitivity: saved.sensitivity, invert: saved.invertTilt)
        if let midLvl = saved.midLevel, let midSeed = saved.midSeed {
            // Cold restore: killed/suspended mid-game. Rebuild the identical
            // maze from (level, seed), put the ball back, recapture tilt.
            var restored = GameModel(level: midLvl, seed: midSeed,
                                     highestLevel: saved.highestLevel,
                                     bestTimes: saved.bestTimes,
                                     sensitivity: saved.sensitivity)
            restored.restoreBall(
                ball: Vec2(saved.midBallX, saved.midBallY),
                velocity: Vec2(saved.midVelX, saved.midVelY),
                elapsed: saved.midElapsed)
            model = restored
            savedLevel = midLvl
            screen = .game
            tilt.start()
            beginCalibration()
            wakeNudgeShown = saved.midElapsed >= Self.wakeNudgeElapsed
            lastMidSaveClock = 0
        } else {
            savedLevel = saved.currentLevel
            model = GameModel(level: saved.currentLevel,
                              seed: Self.randomSeed(),
                              highestLevel: saved.highestLevel,
                              bestTimes: saved.bestTimes,
                              sensitivity: saved.sensitivity)
            trail = Array(repeating: model.physics.position, count: Self.trailLength)
            syncDisplayState()
        }
    }

    private static func randomSeed() -> UInt64 {
        UInt64.random(in: UInt64.min...UInt64.max)
    }

    // MARK: Navigation

    /// Play from the saved level (a fresh maze each time).
    func play() {
        startLevel(savedLevel)
    }

    /// Discard progress and start at level 1.
    func newGame() {
        startLevel(1)
    }

    private func startLevel(_ lvl: Int) {
        model.load(level: lvl, seed: Self.randomSeed())
        savedLevel = lvl
        screen = .game
        tilt.start()
        beginCalibration()
        persist()
    }

    func quitToHome() {
        model.pause()
        tilt.stop()
        lastTick = nil
        screen = .home
        syncDisplayState()
        persist()
    }

    // MARK: Phase control

    func togglePause() {
        switch model.phase {
        case .playing, .countdown: pause()
        case .paused: resume()
        default: break
        }
    }

    func pause() {
        model.pause()
        lastTick = nil
        tilt.resetMotionFilter()
        syncDisplayState()
        persist()
    }

    func resume() {
        model.resume()
        lastTick = nil
        tilt.resetMotionFilter()
        syncDisplayState()
    }

    func recalibrate() {
        model.recalibrate()
        beginCalibration()
    }

    func nextLevel() {
        guard model.phase.isWon else { return }
        model.advanceToNextLevel(seed: Self.randomSeed())
        savedLevel = model.level
        wakeNudgeShown = false
        lastMidSaveClock = 0
        beginCalibration()
        persist()
    }

    func appBecameInactive() {
        guard screen == .game else { return }
        // Screen off / crown / notification: freeze timer (lastTick = nil via
        // pause), drop stale motion state, and snapshot ball + timer so a
        // later kill restores this exact position. Resume stays manual.
        pause()
    }

    private func beginCalibration() {
        lastTick = nil
        resetTrail()
        tilt.beginCalibration()
        isNewBest = false
        wakeNudgeShown = false
        lastMidSaveClock = frameClock
        syncDisplayState()
    }

    // MARK: Frame loop

    /// Called from the view on every TimelineView tick while on the game screen.
    func tick(_ date: Date) {
        guard screen == .game else { return }
        let dt: Double
        if let last = lastTick {
            dt = min(max(date.timeIntervalSince(last), 0), Self.maxFrameDelta)
        } else {
            dt = 0
        }
        lastTick = date
        guard dt > 0 else { return }
        frameClock += dt

        tilt.tick(dt: dt)
        if model.phase == .calibrating {
            if !tilt.isCalibrating { model.finishCalibration() }
            syncDisplayState()
            return
        }

        let events = model.advance(dt: dt, tilt: tilt.current)
        if model.phase.isPlaying || model.phase.isWon { pushTrail(model.physics.position) }
        for event in events { handle(event) }
        syncDisplayState()

        // Single public-API nudge before the 70 s wake timer can expire:
        // tilt never resets the display timer, so buzz once and let the user
        // tap (single taps no longer pause) to keep the screen on.
        if model.phase.isPlaying, !wakeNudgeShown, model.elapsed >= Self.wakeNudgeElapsed {
            wakeNudgeShown = true
            WKInterfaceDevice.current().play(.notification)
        }
        // Lossless autosave: a kill between pauses restores at most 5 s back.
        if model.phase.isPlaying,
           frameClock - lastMidSaveClock >= Self.midSaveInterval {
            lastMidSaveClock = frameClock
            persist()
        }
    }

    private func handle(_ event: GameEvent) {
        let device = WKInterfaceDevice.current()
        switch event {
        case .wallHit(let impact):
            guard impact >= Self.clickMinImpact,
                  frameClock - lastClickTime >= Self.clickMinGap else { return }
            lastClickTime = frameClock
            device.play(.click)
        case .movedInward:
            device.play(.directionUp)
        case .movedOutward:
            break
        case .countdownTick:
            device.play(.click)
        case .go:
            device.play(.start)
        case .won(_, _, let best):
            isNewBest = best
            device.play(.success)
            // Save the next level now, so "Continue" is right even if the app
            // is closed during the win screen.
            savedLevel = model.level + 1
            persist()
        }
    }

    private func syncDisplayState() {
        if phase != model.phase { phase = model.phase }
        if level != model.level { level = model.level }
        if highestLevel != model.highestLevel { highestLevel = model.highestLevel }
        let tenths = Int(model.elapsed * 10)
        if elapsedTenths != tenths { elapsedTenths = tenths }
    }

    // MARK: Trail

    private func resetTrail() {
        trail = Array(repeating: model.physics.position, count: Self.trailLength)
        trailHead = 0
    }

    private func pushTrail(_ p: Vec2) {
        trail[trailHead] = p
        trailHead = (trailHead + 1) % Self.trailLength
    }

    // MARK: Rendering snapshot

    /// Everything the canvas needs for one frame. Cheap value copy; the walls
    /// array is shared storage.
    func renderFrame() -> RenderFrame {
        let maze = model.maze
        var ordered: [Vec2] = []
        ordered.reserveCapacity(Self.trailLength)
        for i in 0..<Self.trailLength {
            ordered.append(trail[(trailHead + i) % Self.trailLength])
        }
        return RenderFrame(
            levelKey: maze.seed ^ UInt64(maze.level),
            walls: maze.walls,
            ringCount: maze.layout.ringCount,
            goalRadius: maze.goalRadius,
            ballPosition: model.physics.position,
            ballRadius: model.physics.ballRadius,
            trail: ordered,
            hasWon: model.physics.hasWon,
            clock: frameClock
        )
    }

    var parTime: Double { model.parTime }
    var bestTimeForCurrentLevel: Double? { model.bestTimeForCurrentLevel }

    // MARK: Persistence

    private func persist() {
        var midLevel: Int? = nil
        var midSeed: UInt64? = nil
        var bx = 0.0, by = 0.0, vx = 0.0, vy = 0.0, el = 0.0
        // Snapshot only while a level is in progress. Home screen, win
        // overlay and explicit quit clear it: Continue then means a fresh maze.
        if screen == .game, !model.phase.isWon {
            midLevel = model.level
            midSeed = model.maze.seed
            bx = model.physics.position.x
            by = model.physics.position.y
            vx = model.physics.velocity.x
            vy = model.physics.velocity.y
            el = model.elapsed
        }
        Persistence.save(SavedState(
            highestLevel: model.highestLevel,
            currentLevel: savedLevel,
            sensitivity: sensitivity,
            invertTilt: invertTilt,
            bestTimes: model.bestTimes,
            midLevel: midLevel,
            midSeed: midSeed,
            midBallX: bx,
            midBallY: by,
            midVelX: vx,
            midVelY: vy,
            midElapsed: el
        ))
    }
}

/// Immutable per-frame snapshot handed to the canvas.
struct RenderFrame {
    let levelKey: UInt64
    let walls: [Wall]
    let ringCount: Int
    let goalRadius: Double
    let ballPosition: Vec2
    let ballRadius: Double
    /// Oldest first, newest last.
    let trail: [Vec2]
    let hasWon: Bool
    /// Monotonic seconds since the session started; drives the hub pulse.
    let clock: TimeInterval
}
