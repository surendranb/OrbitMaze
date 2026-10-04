// Ball physics for OrbitMaze. Pure Swift (no Foundation): stdlib + Darwin only.
//
// Model: the ball is a disc of radius `ballRadius`. Every wall is a stroked
// curve of half-thickness `MazeLayout.wallThickness / 2` with round caps, so
// collision reduces to "distance from the ball centre to the zero-thickness
// curve < ballRadius + halfThickness". Contacts are resolved by positional
// push-out along the contact normal plus a velocity impulse (restitution on
// the normal part, Coulomb friction on the tangential part).
//
// Tunnelling is prevented structurally: the frame is cut into substeps short
// enough that the ball travels less than 40% of its contact radius per
// substep, so its centre can never cross a curve between two resolutions.
//
// Units: maze radius = 1.0, seconds. +y is up (same frame as `Maze`).

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Config

/// Tunable feel parameters. Lengths are maze radii, times are seconds.
public struct PhysicsConfig: Sendable {
    /// Ball radius = factor × ringWidth. 0.30 leaves a one-cell gap ≈ 3× the ball diameter.
    public var ballRadiusFactor: Double
    /// Acceleration at full tilt (maze-radii / s²).
    public var acceleration: Double
    /// Hard speed cap (maze-radii / s).
    public var maxSpeed: Double
    /// Exponential velocity damping rate (1/s): v *= exp(-rollingFriction·dt).
    public var rollingFriction: Double
    /// Fraction of normal speed kept (reversed) on a wall hit. Low = dull, weighty.
    public var restitution: Double
    /// Coulomb friction coefficient against walls (tangential impulse ≤ μ × normal impulse).
    public var wallFriction: Double
    /// Minimum impact speed that reports a `.wallHit` (for haptics).
    public var hitSpeedThreshold: Double
    /// Minimum time between two `.wallHit` events.
    public var hitCooldown: Double

    public init(
        ballRadiusFactor: Double = 0.30,
        acceleration: Double = 3.0,
        maxSpeed: Double = 1.2,
        rollingFriction: Double = 1.2,
        restitution: Double = 0.3,
        wallFriction: Double = 0.12,
        hitSpeedThreshold: Double = 0.2,
        hitCooldown: Double = 0.1
    ) {
        self.ballRadiusFactor = ballRadiusFactor
        self.acceleration = acceleration
        self.maxSpeed = maxSpeed
        self.rollingFriction = rollingFriction
        self.restitution = restitution
        self.wallFriction = wallFriction
        self.hitSpeedThreshold = hitSpeedThreshold
        self.hitCooldown = hitCooldown
    }

    /// Default feel: full tilt reaches max speed in ~0.55 s; coasting halves speed every ~0.6 s.
    public static let standard = PhysicsConfig()
    /// Sensitivity presets.
    public static let low = PhysicsConfig(acceleration: 2.2, maxSpeed: 1.0, restitution: 0.25)
    public static let medium = PhysicsConfig.standard
    public static let high = PhysicsConfig(acceleration: 4.2, maxSpeed: 1.5)
}

// MARK: - Events

public enum PhysicsEvent: Equatable, Sendable {
    /// Ball struck a wall at `impactSpeed` (normal component). Thresholded and rate-limited.
    case wallHit(impactSpeed: Double)
    /// Ring index of the ball centre changed (0 = hub). Small hysteresis prevents chatter.
    case ringChanged(from: Int, to: Int)
    /// Ball centre entered `maze.goalRadius`. Emitted once; afterwards the ball settles to the centre.
    case reachedGoal
}

// MARK: - Precomputed wall shapes

/// Arc with normalised start in [0, 2π) and span in [0, 2π]; endpoints cached.
private struct ArcShape: Sendable {
    let radius: Double
    let start: Double
    let span: Double
    let isFull: Bool
    let ax: Double, ay: Double   // endpoint at `start`
    let bx: Double, by: Double   // endpoint at `start + span`

    init(radius: Double, start s: Double, end e: Double) {
        let twoPi = 2 * Double.pi
        var start = s.truncatingRemainder(dividingBy: twoPi)
        if start < 0 { start += twoPi }
        var span = e - s
        if span < 0 { span += twoPi }
        if span < 0 { span = 0 }
        let full = span >= twoPi - 1e-9
        self.radius = radius
        self.start = start
        self.span = full ? twoPi : span
        self.isFull = full
        ax = radius * cos(start); ay = radius * sin(start)
        let endAngle = start + self.span
        bx = radius * cos(endAngle); by = radius * sin(endAngle)
    }
}

/// Radial segment along unit direction (ux, uy) from `inner` to `outer`.
private struct RadialShape: Sendable {
    let angle: Double
    let ux: Double, uy: Double
    let inner: Double
    let outer: Double

    init(angle: Double, inner: Double, outer: Double) {
        self.angle = angle
        ux = cos(angle); uy = sin(angle)
        self.inner = min(inner, outer)
        self.outer = max(inner, outer)
    }
}

// MARK: - BallPhysics

public struct BallPhysics: Sendable {
    public let maze: Maze
    public let config: PhysicsConfig

    public private(set) var position: Vec2
    public private(set) var velocity: Vec2
    public private(set) var hasWon: Bool
    /// Ring index of the ball centre as last reported via `.ringChanged` (0 = hub).
    public private(set) var currentRing: Int

    public var ballRadius: Double { radius }

    // Derived constants
    private let radius: Double
    private let contactRadius: Double     // ballRadius + wallThickness / 2
    private let substep: Double           // max substep length (s)
    private let ringWidth: Double
    private let ringCount: Int
    private let ringMargin: Double        // hysteresis for ring change

    // Broad-phase: walls bucketed by (ring, angular sector).
    private let arcs: [ArcShape]          // arcs[0] is the implicit outer boundary
    private let radials: [RadialShape]
    private let sectorsPerRing: [Int]
    private let bucketBase: [Int]         // first bucket index of each ring
    private let bucketStart: [Int]        // bucketItems range per bucket (count = buckets + 1)
    private let bucketItems: [Int32]      // < arcs.count → arc index, else radial index + arcs.count

    private var hitCooldownRemaining: Double

    /// Frames longer than this are clamped (a hitch must not launch the ball).
    public static let maxFrameTime = 0.1
    private static let maxSubstep = 0.002
    private static let resolvePasses = 4
    private static let stopSpeed = 1e-3
    private static let settleOmega = 8.0

    // MARK: Init

    public init(maze: Maze, config: PhysicsConfig = .standard) {
        self.maze = maze
        self.config = config
        let layout = maze.layout
        ringWidth = layout.ringWidth
        ringCount = layout.ringCount
        radius = config.ballRadiusFactor * ringWidth
        contactRadius = radius + MazeLayout.wallThickness / 2
        substep = min(Self.maxSubstep, 0.4 * radius / max(config.maxSpeed, 1e-6))
        ringMargin = 0.05 * ringWidth

        var arcs: [ArcShape] = [ArcShape(radius: 1.0, start: 0, end: 2 * .pi)]
        var radials: [RadialShape] = []
        for wall in maze.walls {
            switch wall {
            case let .arc(r, s, e): arcs.append(ArcShape(radius: r, start: s, end: e))
            case let .radial(a, i, o): radials.append(RadialShape(angle: a, inner: i, outer: o))
            }
        }
        self.arcs = arcs
        self.radials = radials

        // Build buckets.
        let twoPi = 2 * Double.pi
        let reach = contactRadius + 1e-9
        var sectors: [Int] = []
        var base: [Int] = []
        var starts: [Int] = [0]
        var items: [Int32] = []
        for ring in 0...ringCount {
            let n = ring == 0 ? 1 : 16
            sectors.append(n)
            base.append(starts.count - 1)
            let lo = Double(ring) * ringWidth - reach
            let hi = Double(ring + 1) * ringWidth + reach
            let innerR = Double(ring) * ringWidth - reach
            let pad: Double = innerR <= 1e-6 ? twoPi : min(twoPi, 2 * reach / innerR + 0.05)
            let sectorWidth = twoPi / Double(n)
            for s in 0..<n {
                let s0 = Double(s) * sectorWidth
                for (i, a) in arcs.enumerated() where a.radius >= lo && a.radius <= hi {
                    if a.isFull || pad >= twoPi
                        || Self.anglesOverlap(a.start - pad, a.span + 2 * pad, s0, sectorWidth) {
                        items.append(Int32(i))
                    }
                }
                for (j, r) in radials.enumerated() where r.outer >= lo && r.inner <= hi {
                    if pad >= twoPi || Self.anglesOverlap(r.angle - pad, 2 * pad, s0, sectorWidth) {
                        items.append(Int32(arcs.count + j))
                    }
                }
                starts.append(items.count)
            }
        }
        sectorsPerRing = sectors
        bucketBase = base
        bucketStart = starts
        bucketItems = items

        position = maze.start
        velocity = .zero
        hasWon = false
        currentRing = min(Int(maze.start.length / ringWidth), ringCount)
        hitCooldownRemaining = 0
    }

    /// True when circular intervals [a0, a0+aSpan] and [b0, b0+bSpan] intersect.
    private static func anglesOverlap(_ a0: Double, _ aSpan: Double, _ b0: Double, _ bSpan: Double) -> Bool {
        let twoPi = 2 * Double.pi
        if aSpan >= twoPi || bSpan >= twoPi { return true }
        func wrap(_ x: Double) -> Double {
            var v = x.truncatingRemainder(dividingBy: twoPi)
            if v < 0 { v += twoPi }
            return v
        }
        return wrap(b0 - a0) <= aSpan || wrap(a0 - b0) <= bSpan
    }

    // MARK: Public control

    /// Put the ball back at the maze start, at rest.
    public mutating func reset() {
        position = maze.start
        velocity = .zero
        hasWon = false
        currentRing = min(Int(maze.start.length / ringWidth), ringCount)
        hitCooldownRemaining = 0
    }

    /// Place the ball with a given velocity (debug, replays, tests). Speed is capped at `maxSpeed`.
    public mutating func launch(position p: Vec2, velocity v: Vec2) {
        position = p
        let s = v.length
        velocity = s > config.maxSpeed ? v * (config.maxSpeed / s) : v
        currentRing = min(Int(p.length / ringWidth), ringCount)
    }

    /// Advance the simulation by `dt` seconds under `tilt` (each axis in [-1, 1], +y up).
    public mutating func step(dt: Double, tilt: Vec2) -> [PhysicsEvent] {
        guard dt > 0, dt.isFinite else { return [] }
        let frame = min(dt, Self.maxFrameTime)
        let n = max(1, Int((frame / substep).rounded(.up)))
        let h = frame / Double(n)

        var t = tilt
        let m = t.length
        if m > 1 { t = t * (1 / m) }
        let tilting = m > 0.02
        let damping = exp(-config.rollingFriction * h)

        var events: [PhysicsEvent] = []
        var maxImpact = 0.0
        let wonAtEntry = hasWon

        for _ in 0..<n {
            integrate(h, tilt: t, tilting: tilting, damping: damping)
            maxImpact = max(maxImpact, resolveCollisions())
            if !hasWon {
                updateRing(&events)
                checkGoal(&events)
            }
        }

        hitCooldownRemaining = max(0, hitCooldownRemaining - frame)
        if !wonAtEntry, maxImpact >= config.hitSpeedThreshold, hitCooldownRemaining <= 0 {
            events.insert(.wallHit(impactSpeed: maxImpact), at: 0)
            hitCooldownRemaining = config.hitCooldown
        }
        return events
    }

    // MARK: Integration

    private mutating func integrate(_ h: Double, tilt: Vec2, tilting: Bool, damping: Double) {
        if hasWon {
            // Critically damped spring to the hub centre.
            let w = Self.settleOmega
            let a = position * (-w * w) - velocity * (2 * w)
            velocity = velocity + a * h
        } else {
            velocity = velocity + tilt * (config.acceleration * h)
            velocity = velocity * damping
        }
        let s = velocity.length
        if s > config.maxSpeed {
            velocity = velocity * (config.maxSpeed / s)
        } else if s < Self.stopSpeed && !tilting && !hasWon {
            velocity = .zero
        }
        position = position + velocity * h
    }

    // MARK: Collision

    /// Pushes the ball out of every wall it overlaps and applies impulses.
    /// Returns the largest normal impact speed seen.
    private mutating func resolveCollisions() -> Double {
        var maxImpact = 0.0
        let twoPi = 2 * Double.pi
        let cr = contactRadius
        let cr2 = cr * cr
        let e = config.restitution
        let mu = config.wallFriction

        // Broad-phase bucket from the position at entry; padding covers the push-out drift.
        let len0 = position.length
        let ring = min(Int(len0 / ringWidth), ringCount)
        var theta0 = atan2(position.y, position.x)
        if theta0 < 0 { theta0 += twoPi }
        let n = sectorsPerRing[ring]
        let sector = min(Int(theta0 / twoPi * Double(n)), n - 1)
        let bucket = bucketBase[ring] + sector
        let lo = bucketStart[bucket], hi = bucketStart[bucket + 1]

        for _ in 0..<Self.resolvePasses {
            var touched = false
            var px = position.x, py = position.y
            var theta = atan2(py, px)
            if theta < 0 { theta += twoPi }
            var plen = (px * px + py * py).squareRoot()

            for k in lo..<hi {
                let i = Int(bucketItems[k])
                var cx = 0.0, cy = 0.0
                if i < arcs.count {
                    let a = arcs[i]
                    var onBody = a.isFull
                    if !onBody {
                        var rel = theta - a.start
                        if rel < 0 { rel += twoPi }
                        onBody = rel <= a.span
                    }
                    if onBody {
                        if plen > 1e-12 {
                            let s = a.radius / plen
                            cx = px * s; cy = py * s
                        } else {
                            cx = a.radius; cy = 0
                        }
                    } else {
                        let dax = px - a.ax, day = py - a.ay
                        let dbx = px - a.bx, dby = py - a.by
                        if dax * dax + day * day <= dbx * dbx + dby * dby {
                            cx = a.ax; cy = a.ay
                        } else {
                            cx = a.bx; cy = a.by
                        }
                    }
                } else {
                    let r = radials[i - arcs.count]
                    let t = px * r.ux + py * r.uy
                    let tc = min(max(t, r.inner), r.outer)
                    cx = r.ux * tc; cy = r.uy * tc
                }

                let dx = px - cx, dy = py - cy
                let d2 = dx * dx + dy * dy
                if d2 >= cr2 { continue }

                let d = d2.squareRoot()
                var nx: Double, ny: Double
                if d > 1e-12 {
                    nx = dx / d; ny = dy / d
                } else if plen > 1e-12 {
                    nx = px / plen; ny = py / plen
                } else {
                    nx = 1; ny = 0
                }
                let pen = cr - d
                px += nx * pen; py += ny * pen
                // Polar cache must follow the new centre, or a later wall in
                // this pass would use a closest point that is off its curve.
                plen = (px * px + py * py).squareRoot()
                theta = atan2(py, px)
                if theta < 0 { theta += twoPi }

                let vn = velocity.x * nx + velocity.y * ny
                if vn < 0 {
                    let impact = -vn
                    if impact > maxImpact { maxImpact = impact }
                    let jn = (1 + e) * impact
                    var vx = velocity.x + nx * jn
                    var vy = velocity.y + ny * jn
                    // Coulomb friction on the tangential component.
                    let tx = -ny, ty = nx
                    let vt = vx * tx + vy * ty
                    let jt = min(abs(vt), mu * jn)
                    let sgn: Double = vt >= 0 ? 1 : -1
                    vx -= tx * jt * sgn
                    vy -= ty * jt * sgn
                    velocity = Vec2(vx, vy)
                }
                touched = true
            }
            position = Vec2(px, py)
            if !touched { break }
        }

        // Hard invariant: the ball never leaves the unit disc.
        let limit = 1.0 - radius
        let plen = position.length
        if plen > limit {
            let nx = position.x / plen, ny = position.y / plen
            position = Vec2(nx * limit, ny * limit)
            let vn = velocity.x * nx + velocity.y * ny
            if vn > 0 {
                velocity = velocity - Vec2(nx, ny) * ((1 + e) * vn)
            }
        }
        return maxImpact
    }

    // MARK: Events

    private mutating func updateRing(_ events: inout [PhysicsEvent]) {
        let d = position.length
        let r = min(Int(d / ringWidth), ringCount)
        if r == currentRing { return }
        if r > currentRing {
            guard d >= Double(currentRing + 1) * ringWidth + ringMargin else { return }
        } else {
            guard d <= Double(currentRing) * ringWidth - ringMargin else { return }
        }
        events.append(.ringChanged(from: currentRing, to: r))
        currentRing = r
    }

    private mutating func checkGoal(_ events: inout [PhysicsEvent]) {
        guard position.length < maze.goalRadius else { return }
        hasWon = true
        if currentRing != 0 {
            events.append(.ringChanged(from: currentRing, to: 0))
            currentRing = 0
        }
        events.append(.reachedGoal)
    }
}
