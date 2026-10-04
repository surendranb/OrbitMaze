// Game state machine and level progression. Pure Swift (no Foundation).
//
// Phases:   calibrating → countdown(3) → playing → won → (next level) → calibrating …
//           playing ⇄ paused (resume goes through a 1 s countdown;
//           recalibrate goes back to calibrating).
//
// Par time for a level (documented in `parTime(solutionLength:layout:)`):
//   par = (0.1 s + solutionLength × (0.32 s + 0.45 s × ringWidth)) × margin
// i.e. the playtest PD bot's time scaled by a margin that tightens from 1.45
// (level 1) towards 1.20 as solutions get longer.
// Stars: 3 if time ≤ par, 2 if time ≤ 1.6 × par, else 1.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Settings

/// Sensitivity preset. Changes both the physics feel and how much wrist tilt
/// counts as "full".
public enum Sensitivity: Int, CaseIterable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    public var physics: PhysicsConfig {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }

    /// Wrist tilt (degrees) that gives full acceleration.
    public var fullTiltDegrees: Double {
        switch self {
        case .low: return 20
        case .medium: return 15
        case .high: return 11
        }
    }

    public var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        }
    }
}

// MARK: - Phase & events

public enum GamePhase: Equatable, Sendable {
    /// Sampling the neutral wrist pose. The view shows "Hold still".
    case calibrating
    /// Counting down; `remaining` in seconds (starts at 3, or 1 after a resume).
    case countdown(remaining: Double)
    case playing
    case paused
    case won(time: Double, stars: Int)

    public var isPlaying: Bool { self == .playing }
    public var isWon: Bool { if case .won = self { return true } else { return false } }
}

public enum GameEvent: Equatable, Sendable {
    case wallHit(impactSpeed: Double)
    case movedInward(toRing: Int)
    case movedOutward(toRing: Int)
    /// Countdown digit changed (3, 2, 1).
    case countdownTick(Int)
    /// Countdown finished; the ball is live.
    case go
    case won(time: Double, stars: Int, isNewBest: Bool)
}

// MARK: - Model

public struct GameModel: Sendable {
    public static let countdownSeconds = 3.0
    public static let resumeCountdownSeconds = 1.0

    public private(set) var level: Int
    public private(set) var highestLevel: Int
    /// Best completion time per level (seconds).
    public private(set) var bestTimes: [Int: Double]
    public private(set) var sensitivity: Sensitivity
    public private(set) var phase: GamePhase
    public private(set) var physics: BallPhysics
    /// Seconds spent in `.playing` for the current level.
    public private(set) var elapsed: Double
    public private(set) var parTime: Double
    public private(set) var solutionLength: Int

    public var maze: Maze { physics.maze }
    public var bestTimeForCurrentLevel: Double? { bestTimes[level] }

    public init(level: Int, seed: UInt64, highestLevel: Int, bestTimes: [Int: Double], sensitivity: Sensitivity) {
        let lvl = max(1, level)
        let maze = MazeGenerator.generate(level: lvl, seed: seed)
        self.level = lvl
        self.highestLevel = max(highestLevel, lvl)
        self.bestTimes = bestTimes
        self.sensitivity = sensitivity
        self.physics = BallPhysics(maze: maze, config: sensitivity.physics)
        self.phase = .calibrating
        self.elapsed = 0
        self.solutionLength = MazeSolver.solutionLength(of: maze)
        self.parTime = Self.parTime(solutionLength: solutionLength, layout: maze.layout)
    }

    // MARK: Par & stars

    /// Par time (the 3★ threshold) for a maze whose solution is
    /// `solutionLength` cells long (start included, hub excluded) on `layout`.
    /// Pure; depends only on its arguments.
    ///
    ///     bot    = 0.1 + L · (0.32 + 0.45 · ringWidth)
    ///     margin = 1.20 + 0.25 · exp(−max(0, L − 18) / 25)
    ///     par    = bot · margin
    ///
    /// `bot` is the time the playtest's PD bot (`Tests/PlaytestTests.swift`,
    /// `.standard` physics, no lag or noise) needs: a fit over 3...7 rings and
    /// 12...80 cells with rmse ≤ 0.65 s. The margin is 1.45 at level 1
    /// (L = 18 cells) and tightens towards 1.20 as the solution grows — and the
    /// solution grows with the level — so late levels keep something to chase
    /// while the bot always clears par by ≥ 20 %. The humanlike playtest
    /// profile lands at 1.2–1.7 × par, i.e. 2★ early and 1★ late.
    public static func parTime(solutionLength: Int, layout: MazeLayout) -> Double {
        let cells = Double(max(1, solutionLength))
        let bot = 0.1 + cells * (0.32 + 0.45 * layout.ringWidth)
        let margin = 1.20 + 0.25 * exp(-max(0, cells - 18) / 25)
        return bot * margin
    }

    /// Stars: 3 if time ≤ par, 2 if time ≤ 1.6 × par, else 1.
    public static func stars(time: Double, par: Double) -> Int {
        if time <= par { return 3 }
        if time <= par * 1.6 { return 2 }
        return 1
    }

    // MARK: Level control

    /// Build a fresh maze for `level` and go to `.calibrating`.
    public mutating func load(level newLevel: Int, seed: UInt64) {
        let lvl = max(1, newLevel)
        let maze = MazeGenerator.generate(level: lvl, seed: seed)
        level = lvl
        highestLevel = max(highestLevel, lvl)
        physics = BallPhysics(maze: maze, config: sensitivity.physics)
        phase = .calibrating
        elapsed = 0
        solutionLength = MazeSolver.solutionLength(of: maze)
        parTime = Self.parTime(solutionLength: solutionLength, layout: maze.layout)
    }

    public mutating func advanceToNextLevel(seed: UInt64) {
        load(level: level + 1, seed: seed)
    }

    public mutating func restartLevel(seed: UInt64) {
        load(level: level, seed: seed)
    }

    /// Rebuilds the physics with the new preset. The ball returns to the start;
    /// callers should only do this between levels or from the pause menu.
    public mutating func setSensitivity(_ s: Sensitivity) {
        guard s != sensitivity else { return }
        sensitivity = s
        physics = BallPhysics(maze: physics.maze, config: s.physics)
        if phase.isPlaying || phase == .paused || phase == .calibrating {
            elapsed = 0
            phase = .calibrating
        }
    }

    // MARK: Phase transitions

    /// Called by the tilt layer when the neutral pose has been captured.
    public mutating func finishCalibration() {
        guard phase == .calibrating else { return }
        phase = .countdown(remaining: Self.countdownSeconds)
    }

    public mutating func pause() {
        switch phase {
        case .playing, .countdown: phase = .paused
        default: break
        }
    }

    public mutating func resume() {
        guard phase == .paused else { return }
        phase = .countdown(remaining: Self.resumeCountdownSeconds)
    }

    public mutating func recalibrate() {
        guard phase == .paused || phase.isPlaying else { return }
        phase = .calibrating
    }

    /// Cold-restore helper: after `load(level:seed:)` rebuilds the identical
    /// maze, put the ball back where it was with its velocity and timer.
    /// Phase is left untouched (`.calibrating` after a load), so tilt is
    /// recaptured before the countdown. Pure state injection, no I/O.
    public mutating func restoreBall(ball: Vec2, velocity: Vec2, elapsed newElapsed: Double) {
        physics.launch(position: ball, velocity: velocity)
        elapsed = max(0, newElapsed)
    }

    // MARK: Simulation

    /// Advance the game by `dt` seconds under `tilt` (maze frame, |tilt| ≤ 1).
    /// Safe to call in any phase; only countdown/playing/won do work.
    public mutating func advance(dt: Double, tilt: Vec2) -> [GameEvent] {
        guard dt > 0, dt.isFinite else { return [] }
        var events: [GameEvent] = []

        switch phase {
        case .countdown(let remaining):
            let before = Int(remaining.rounded(.up))
            let after = remaining - dt
            if after <= 0 {
                phase = .playing
                events.append(.go)
            } else {
                let digit = Int(after.rounded(.up))
                if digit != before { events.append(.countdownTick(digit)) }
                phase = .countdown(remaining: after)
            }

        case .playing:
            elapsed += dt
            for e in physics.step(dt: dt, tilt: tilt) {
                switch e {
                case .wallHit(let s):
                    events.append(.wallHit(impactSpeed: s))
                case .ringChanged(let from, let to):
                    events.append(to < from ? .movedInward(toRing: to) : .movedOutward(toRing: to))
                case .reachedGoal:
                    let time = elapsed
                    let stars = Self.stars(time: time, par: parTime)
                    let previous = bestTimes[level]
                    let isBest = previous.map { time < $0 } ?? true
                    if isBest { bestTimes[level] = time }
                    highestLevel = max(highestLevel, level + 1)
                    phase = .won(time: time, stars: stars)
                    events.append(.won(time: time, stars: stars, isNewBest: isBest))
                }
            }

        case .won:
            // Let the ball settle into the hub; ignore tilt and events.
            _ = physics.step(dt: dt, tilt: .zero)

        case .calibrating, .paused:
            break
        }
        return events
    }

    /// Current countdown digit to display (3, 2, 1), or nil.
    public var countdownDigit: Int? {
        if case .countdown(let r) = phase { return max(1, Int(r.rounded(.up))) }
        return nil
    }
}

// MARK: - Formatting (no Foundation)

public enum TimeFormat {
    /// "12.3" for under a minute, "1:02.3" above. Tenths of a second.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int((seconds * 10).rounded(.down)))
        let tenths = total % 10
        let secs = (total / 10) % 60
        let mins = total / 600
        if mins == 0 { return "\(secs).\(tenths)" }
        let s = secs < 10 ? "0\(secs)" : "\(secs)"
        return "\(mins):\(s).\(tenths)"
    }
}
