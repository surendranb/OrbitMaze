// Standalone physics tests. Build:
//   swiftc -O -parse-as-library Core/Geometry.swift Core/BallPhysics.swift Tests/PhysicsTests.swift -o physics_tests
// Mazes are hand-built; MazeGenerator is not needed.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Harness

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond {
        passes += 1
        print("PASS  \(name)")
    } else {
        failures += 1
        let d = detail()
        print("FAIL  \(name)\(d.isEmpty ? "" : "  -- \(d)")")
    }
}

func fmt(_ x: Double, _ digits: Int = 4) -> String {
    let p = pow(10.0, Double(digits))
    let v = (x * p).rounded() / p
    return "\(v)"
}

func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

let twoPi = 2 * Double.pi

func polar(_ r: Double, _ a: Double) -> Vec2 { Vec2(r * cos(a), r * sin(a)) }

func wrapAngle(_ a: Double) -> Double {
    var v = a.truncatingRemainder(dividingBy: twoPi)
    if v < 0 { v += twoPi }
    return v
}

/// Independent clearance check: min over walls of (distance to curve) − (ballRadius + t/2).
/// Negative = ball overlaps a wall.
func clearance(_ maze: Maze, _ p: Vec2, ballRadius: Double) -> Double {
    let half = MazeLayout.wallThickness / 2
    var best = Double.infinity
    let len = p.length
    let theta = p.angle
    for w in maze.walls {
        var d: Double
        switch w {
        case let .arc(radius, start, end):
            var span = end - start
            if span < 0 { span += twoPi }
            let full = span >= twoPi - 1e-9
            let s0 = wrapAngle(start)
            var rel = theta - s0
            if rel < 0 { rel += twoPi }
            if full || rel <= span {
                d = abs(len - radius)
            } else {
                let a = polar(radius, s0), b = polar(radius, s0 + span)
                d = min((p - a).length, (p - b).length)
            }
        case let .radial(angle, inner, outer):
            let u = Vec2(cos(angle), sin(angle))
            let t = min(max(p.dot(u), inner), outer)
            d = (p - u * t).length
        }
        best = min(best, d - (ballRadius + half))
    }
    best = min(best, (1.0 - len) - (ballRadius + half))
    return best
}

func makeLayout(_ ringCount: Int) -> MazeLayout {
    var cells = [1]
    var n = 8
    for r in 1...ringCount {
        cells.append(n)
        if r % 2 == 0 { n *= 2 }
    }
    return MazeLayout(ringCount: ringCount, cellsPerRing: cells)
}

func makeMaze(_ layout: MazeLayout, walls: [Wall], start: Vec2, goalRadius: Double) -> Maze {
    Maze(seed: 1, level: 1, layout: layout, walls: [.arc(radius: 1.0, start: 0, end: twoPi)] + walls,
         start: start, goalRadius: goalRadius)
}

func randomUnit(_ rng: inout SplitMix64) -> Double { Double(rng.next() >> 11) / Double(1 << 53) }

// MARK: - Tests

@main
struct PhysicsTests {
    static func main() {
        testFreeRoll()
        testNoTunnelling()
        testArcWrap()
        testGapSlide()
        testArcCaps()
        testEventsAndRest()
        testPerf()
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // 1. Free roll: accelerates along tilt, caps at maxSpeed.
    static func testFreeRoll() {
        print("\n[free roll]")
        let layout = makeLayout(7)
        let maze = makeMaze(layout, walls: [], start: Vec2(-0.8, 0), goalRadius: 0)
        var ball = BallPhysics(maze: maze)
        let cfg = ball.config

        for _ in 0..<18 { _ = ball.step(dt: 1.0 / 60, tilt: Vec2(1, 0)) }  // 0.3 s
        check(ball.velocity.x > 0.5, "free roll accelerates in +x", "vx=\(fmt(ball.velocity.x))")
        check(abs(ball.velocity.y) < 1e-9, "free roll has no cross-axis drift")
        check(ball.position.x > -0.8, "free roll moved +x")
        check(ball.velocity.x < cfg.maxSpeed + 1e-9, "speed ≤ maxSpeed during spin-up")

        for _ in 0..<42 { _ = ball.step(dt: 1.0 / 60, tilt: Vec2(1, 0)) }  // to 1.0 s
        let s = ball.velocity.length
        check(abs(s - cfg.maxSpeed) < 1e-6, "reaches and holds maxSpeed", "speed=\(fmt(s, 6))")
        check(ball.position.x < 1.0 - ball.ballRadius, "still inside boundary")

        // Diagonal tilt with magnitude > 1 is clamped, direction kept.
        var ball2 = BallPhysics(maze: maze)
        for _ in 0..<60 { _ = ball2.step(dt: 1.0 / 60, tilt: Vec2(3, 3)) }
        check(abs(ball2.velocity.x - ball2.velocity.y) < 1e-9, "diagonal tilt keeps direction")
        check(ball2.velocity.length <= cfg.maxSpeed + 1e-9, "over-unit tilt is clamped")

        // Coasting: no tilt → decays.
        let before = ball.velocity.length
        for _ in 0..<30 { _ = ball.step(dt: 1.0 / 60, tilt: .zero) }
        check(ball.velocity.length < before * 0.7, "rolling friction decays speed",
              "\(fmt(before)) → \(fmt(ball.velocity.length))")

        // Large dt is clamped (no teleport).
        var ball3 = BallPhysics(maze: maze)
        _ = ball3.step(dt: 5.0, tilt: Vec2(1, 0))
        check(ball3.position.x < -0.7, "huge dt clamped", "x=\(fmt(ball3.position.x))")
    }

    // 2. No tunnelling: sealed cell (arc below, radials both sides, outer boundary).
    static func testNoTunnelling() {
        print("\n[no tunnelling]")
        let layout = makeLayout(7)  // ringWidth 0.125
        var walls: [Wall] = [.arc(radius: 0.5, start: 0, end: twoPi)]
        for k in 0..<16 {
            walls.append(.radial(angle: Double(k) * .pi / 8, inner: 0.5, outer: 1.0))
        }
        let maze = makeMaze(layout, walls: walls, start: polar(0.75, 3.5 * .pi / 8), goalRadius: 0)
        var ball = BallPhysics(maze: maze)
        let R = ball.ballRadius
        let maxSpeed = ball.config.maxSpeed
        let aLo = 3 * Double.pi / 8, aHi = 4 * Double.pi / 8

        func runTrial(pos: Vec2, vel: Vec2, tilt: Vec2, frames: Int, dt: Double) -> (ok: Bool, why: String) {
            ball.launch(position: pos, velocity: vel)
            for f in 0..<frames {
                _ = ball.step(dt: dt, tilt: tilt)
                let p = ball.position
                let len = p.length
                let ang = p.angle
                if len + R > 1.0 + 1e-9 { return (false, "left unit disc at frame \(f): |p|=\(fmt(len))") }
                if len < 0.5 { return (false, "crossed arc at frame \(f): |p|=\(fmt(len))") }
                if ang < aLo - 1e-9 || ang > aHi + 1e-9 { return (false, "crossed radial at frame \(f): ang=\(fmt(ang))") }
                let c = clearance(maze, p, ballRadius: R)
                if c < -1e-7 { return (false, "penetration \(fmt(c, 6)) at frame \(f)") }
            }
            return (true, "")
        }

        // Deterministic: 36 directions from 3 start points at maxSpeed, tilt along velocity.
        var ok = true
        var why = ""
        let starts = [polar(0.6, 3.5 * .pi / 8), polar(0.75, 3.2 * .pi / 8), polar(0.9, 3.8 * .pi / 8)]
        for s in starts {
            for i in 0..<36 {
                let a = Double(i) * twoPi / 36
                let dir = Vec2(cos(a), sin(a))
                let r = runTrial(pos: s, vel: dir * maxSpeed, tilt: dir, frames: 45, dt: 1.0 / 15)
                if !r.ok { ok = false; why = "start=\(s) dir=\(fmt(a)): \(r.why)"; break }
            }
            if !ok { break }
        }
        check(ok, "108 directed shots at maxSpeed, dt=1/15: never cross arc/radial/outer", why)

        // Random: 300 trials, random pos/vel/tilt.
        var rng = SplitMix64(seed: 42)
        ok = true
        for trial in 0..<300 {
            var pos = Vec2.zero
            repeat {
                pos = polar(0.5 + 0.5 * randomUnit(&rng), aLo + (aHi - aLo) * randomUnit(&rng))
            } while clearance(maze, pos, ballRadius: R) < 0.001
            let va = twoPi * randomUnit(&rng)
            let ta = twoPi * randomUnit(&rng)
            let tm = randomUnit(&rng)
            let r = runTrial(pos: pos, vel: Vec2(cos(va), sin(va)) * maxSpeed,
                             tilt: Vec2(cos(ta), sin(ta)) * tm, frames: 45, dt: 1.0 / 15)
            if !r.ok { ok = false; why = "trial \(trial): \(r.why)"; break }
        }
        check(ok, "300 random shots at maxSpeed, dt=1/15: never cross, never penetrate", why)

        // High sensitivity preset too (faster ball).
        var fast = BallPhysics(maze: maze, config: .high)
        ok = true
        for i in 0..<36 {
            let a = Double(i) * twoPi / 36
            let dir = Vec2(cos(a), sin(a))
            fast.launch(position: polar(0.75, 3.5 * .pi / 8), velocity: dir * fast.config.maxSpeed)
            for f in 0..<45 {
                _ = fast.step(dt: 1.0 / 15, tilt: dir)
                let p = fast.position
                if p.length < 0.5 || p.angle < aLo - 1e-9 || p.angle > aHi + 1e-9 || p.length + fast.ballRadius > 1 + 1e-9 {
                    ok = false; why = "dir \(fmt(a)) frame \(f) p=\(p)"; break
                }
            }
            if !ok { break }
        }
        check(ok, ".high preset: 36 shots never cross", why)
    }

    // 3. Arc wrapping past angle 0.
    static func testArcWrap() {
        print("\n[arc wrap-around]")
        let layout = makeLayout(7)
        let maze = makeMaze(layout, walls: [.arc(radius: 0.5, start: 5.5, end: 0.5)],
                            start: .zero, goalRadius: 0)
        var ball = BallPhysics(maze: maze)
        let R = ball.ballRadius
        for a in [0.0, 6.0, 0.3, 5.6, 0.45] {
            let dir = Vec2(cos(a), sin(a))
            ball.launch(position: .zero, velocity: dir * ball.config.maxSpeed)
            var crossed = false
            var pen = 0.0
            for _ in 0..<30 {
                _ = ball.step(dt: 1.0 / 15, tilt: dir)
                if ball.position.length >= 0.5 { crossed = true }
                pen = min(pen, clearance(maze, ball.position, ballRadius: R))
            }
            check(!crossed && pen > -1e-7, "wrapped arc blocks at angle \(fmt(a, 2))",
                  "|p|=\(fmt(ball.position.length)) minClearance=\(fmt(pen, 6))")
        }
        for a in [3.0, 1.0, 5.0] {
            let dir = Vec2(cos(a), sin(a))
            ball.launch(position: .zero, velocity: dir * ball.config.maxSpeed)
            for _ in 0..<30 { _ = ball.step(dt: 1.0 / 15, tilt: dir) }
            check(ball.position.length > 0.6, "wrapped arc open at angle \(fmt(a, 2))", "|p|=\(fmt(ball.position.length))")
        }
    }

    // 4. One-cell gap: ball tilted toward it drops to the inner ring.
    static func gapMaze() -> (Maze, Double, Double) {
        // ringCount 4 → ringWidth 0.2. Ring 3 spans [0.6, 0.8], 16 cells; cell 4 = [π/2, π/2 + π/8].
        let layout = MazeLayout(ringCount: 4, cellsPerRing: [1, 8, 8, 16, 16])
        let gapLo = Double.pi / 2
        let gapHi = Double.pi / 2 + Double.pi / 8
        let walls: [Wall] = [
            .arc(radius: 0.6, start: gapHi, end: gapLo),   // everything except the gap (wraps)
            .arc(radius: 0.4, start: 0, end: twoPi),
        ]
        let start = polar(0.7, (gapLo + gapHi) / 2)
        return (makeMaze(layout, walls: walls, start: start, goalRadius: 0), gapLo, gapHi)
    }

    static func testGapSlide() {
        print("\n[gap slide]")
        let (maze, _, _) = gapMaze()
        var ball = BallPhysics(maze: maze)
        var ringEvents: [PhysicsEvent] = []
        var reached = false
        var minClear = 0.0
        for _ in 0..<60 {
            let tilt = ball.position.normalized * -1
            let ev = ball.step(dt: 1.0 / 30, tilt: tilt)
            ringEvents += ev.filter { if case .ringChanged = $0 { return true } else { return false } }
            minClear = min(minClear, clearance(maze, ball.position, ballRadius: ball.ballRadius))
            if ball.position.length < 0.6 - ball.ballRadius { reached = true }
        }
        check(reached, "ball slides through one-cell gap to inner ring", "|p|=\(fmt(ball.position.length))")
        check(ringEvents.first == .ringChanged(from: 3, to: 2), "ringChanged(3→2) fired", "\(ringEvents)")
        check(ringEvents.count == 1, "exactly one ringChanged", "\(ringEvents)")
        check(minClear > -1e-7, "no penetration while passing gap", "min=\(fmt(minClear, 6))")
        check(ball.position.length > 0.4, "stopped by inner arc at 0.4", "|p|=\(fmt(ball.position.length))")
    }

    // 5. Arc endpoint caps.
    static func testArcCaps() {
        print("\n[arc caps]")
        let (maze, gapLo, gapHi) = gapMaze()
        var ball = BallPhysics(maze: maze)
        let R = ball.ballRadius
        let half = MazeLayout.wallThickness / 2
        let endA = polar(0.6, gapLo)   // cap at the gap's lower edge
        let endB = polar(0.6, gapHi)

        // Centre angle just inside the gap, disc overlapping the cap: ball must not pass through the end.
        for (name, ang, cap) in [("lower edge", gapLo + 0.02, endA), ("upper edge", gapHi - 0.02, endB)] {
            ball.launch(position: polar(0.78, ang), velocity: polar(1, ang) * -ball.config.maxSpeed)
            var minCapDist = Double.infinity
            var minClear = Double.infinity
            for _ in 0..<45 {
                _ = ball.step(dt: 1.0 / 15, tilt: polar(1, ang) * -1)
                minCapDist = min(minCapDist, (ball.position - cap).length)
                minClear = min(minClear, clearance(maze, ball.position, ballRadius: R))
            }
            check(minCapDist >= R + half - 1e-7, "cap at \(name) is solid", "minDist=\(fmt(minCapDist, 5)) need=\(fmt(R + half, 5))")
            check(minClear > -1e-7, "no penetration at \(name)", "min=\(fmt(minClear, 6))")
            check(ball.position.length < 0.6 - R, "ball deflects off \(name) cap and still gets through", "|p|=\(fmt(ball.position.length))")
        }

        // Centre angle just outside the gap, over the wall body: blocked.
        for (name, ang) in [("below gap", gapLo - 0.03), ("above gap", gapHi + 0.03)] {
            ball.launch(position: polar(0.78, ang), velocity: polar(1, ang) * -ball.config.maxSpeed)
            var minClear = Double.infinity
            var crossed = false
            for _ in 0..<45 {
                _ = ball.step(dt: 1.0 / 15, tilt: polar(1, ang) * -1)
                minClear = min(minClear, clearance(maze, ball.position, ballRadius: R))
                if ball.position.length < 0.6 && (ball.position.angle < gapLo || ball.position.angle > gapHi) { crossed = true }
            }
            check(!crossed && minClear > -1e-7, "arc body near end blocks (\(name))", "min=\(fmt(minClear, 6))")
        }

        // Sliding along the arc toward the end: rounds the cap, no snag, no tunnel.
        ball.launch(position: polar(0.6 + R + half + 0.002, gapLo - 0.5), velocity: polar(1, gapLo - 0.5 + .pi / 2) * 0.8)
        var minClear = Double.infinity
        for _ in 0..<60 {
            _ = ball.step(dt: 1.0 / 15, tilt: Vec2(0.7, -0.7))
            minClear = min(minClear, clearance(maze, ball.position, ballRadius: R))
        }
        check(minClear > -1e-7, "sliding past an arc end never penetrates", "min=\(fmt(minClear, 6))")
    }

    // 6. Events, debounce, resting.
    static func testEventsAndRest() {
        print("\n[events / rest]")
        // Goal: open maze, roll from ring 3 to centre.
        let layout = MazeLayout(ringCount: 4, cellsPerRing: [1, 8, 8, 16, 16])
        let maze = makeMaze(layout, walls: [], start: Vec2(0, 0.7), goalRadius: layout.ringWidth)
        var ball = BallPhysics(maze: maze)
        var all: [PhysicsEvent] = []
        var goalCount = 0
        var afterWin: [PhysicsEvent] = []
        for _ in 0..<180 {
            let ev = ball.step(dt: 1.0 / 60, tilt: Vec2(0, -1))
            if ball.hasWon && goalCount > 0 { afterWin += ev }
            all += ev
            goalCount += ev.filter { $0 == .reachedGoal }.count
        }
        let rings = all.compactMap { e -> (Int, Int)? in if case let .ringChanged(f, t) = e { return (f, t) } else { return nil } }
        check(rings.map { $0.0 } == [3, 2, 1] && rings.map { $0.1 } == [2, 1, 0], "ringChanged 3→2→1→0 in order", "\(rings)")
        check(goalCount == 1, "reachedGoal exactly once", "count=\(goalCount)")
        check(ball.hasWon, "hasWon set")
        check(afterWin.isEmpty, "no events after win", "\(afterWin)")
        check(ball.position.length < 0.01, "ball settles to centre after win", "|p|=\(fmt(ball.position.length))")
        ball.reset()
        check(!ball.hasWon && ball.position == maze.start && ball.velocity == .zero, "reset restores start")

        // Debounce: slam into outer wall, keep pushing for 2 s.
        let open = makeMaze(makeLayout(7), walls: [], start: Vec2(0.5, 0), goalRadius: 0)
        var b = BallPhysics(maze: open)
        var hits: [Double] = []
        var frames = 0
        var firstHitFrame = -1
        while frames < 180 {  // 3 s
            let ev = b.step(dt: 1.0 / 60, tilt: Vec2(1, 0))
            for e in ev { if case let .wallHit(s) = e { hits.append(s); if firstHitFrame < 0 { firstHitFrame = frames } } }
            frames += 1
        }
        check(hits.count >= 1, "wallHit fired on impact", "hits=\(hits.map { fmt($0, 3) })")
        check(hits.count <= 2, "wallHit debounced while resting (≤2 over 3 s)", "hits=\(hits.map { fmt($0, 3) })")
        check((hits.first ?? 0) > 1.0, "first impact speed is near maxSpeed", "\(fmt(hits.first ?? 0, 3))")

        // Rest: no jitter over 1 s.
        let p0 = b.position
        var maxDrift = 0.0
        for _ in 0..<60 {
            _ = b.step(dt: 1.0 / 60, tilt: Vec2(1, 0))
            maxDrift = max(maxDrift, (b.position - p0).length)
        }
        check(maxDrift < 1e-5, "resting against wall under tilt: no jitter", "drift=\(fmt(maxDrift, 8))")
        check(abs(b.position.length + b.ballRadius + MazeLayout.wallThickness / 2 - 1.0) < 1e-6, "rests exactly on wall surface",
              "|p|=\(fmt(b.position.length, 8)) R=\(fmt(b.ballRadius, 8)) p=\(b.position)")
        check(b.velocity.length < 0.02, "resting velocity ~0", "v=\(fmt(b.velocity.length, 6))")

        // Rest in a corner (arc + radial) under diagonal tilt: no jitter, no escape.
        var cw: [Wall] = [.arc(radius: 0.5, start: 0, end: twoPi)]
        cw.append(.radial(angle: 0, inner: 0.5, outer: 1.0))
        let corner = makeMaze(makeLayout(7), walls: cw, start: polar(0.7, 0.3), goalRadius: 0)
        var c = BallPhysics(maze: corner)
        var cornerHits = 0
        let cornerTilt = Vec2(-0.5, -0.86)   // inward along the radial, down onto it
        for _ in 0..<180 {
            let ev = c.step(dt: 1.0 / 60, tilt: cornerTilt)
            cornerHits += ev.filter { if case .wallHit = $0 { return true } else { return false } }.count
        }
        let c0 = c.position
        var cDrift = 0.0
        for _ in 0..<60 {
            _ = c.step(dt: 1.0 / 60, tilt: cornerTilt)
            cDrift = max(cDrift, (c.position - c0).length)
        }
        check(cDrift < 1e-5, "corner rest: no jitter", "drift=\(fmt(cDrift, 8))")
        check(abs(c.position.y - (c.ballRadius + MazeLayout.wallThickness / 2)) < 1e-6
              && abs(c.position.length - (0.5 + c.ballRadius + MazeLayout.wallThickness / 2)) < 1e-6,
              "corner rest: pinned against both walls", "p=\(c.position)")
        check(cornerHits <= 3, "corner: few wallHit events", "hits=\(cornerHits)")
        check(clearance(corner, c.position, ballRadius: c.ballRadius) > -1e-7, "corner: no penetration")
    }

    // 7. Perf on a ~150-wall maze.
    static func perfMaze() -> Maze {
        let layout = makeLayout(7)   // cells [1,8,8,16,16,32,32,64]
        let rw = layout.ringWidth
        var walls: [Wall] = []
        for r in 1...layout.ringCount {
            let n = layout.cellsPerRing[r]
            let w = twoPi / Double(n)
            let inner = layout.innerRadius(ring: r)
            for c in 0..<n {
                if (c + r) % 4 != 0 { walls.append(.arc(radius: inner, start: Double(c) * w, end: Double(c + 1) * w)) }
                if (c + 2 * r) % 5 == 0 { walls.append(.radial(angle: Double(c) * w, inner: inner, outer: inner + rw)) }
            }
        }
        let start = polar(layout.innerRadius(ring: 7) + rw / 2, twoPi / 128)
        return makeMaze(layout, walls: walls, start: start, goalRadius: rw)
    }

    static func testPerf() {
        print("\n[perf]")
        let maze = perfMaze()
        print("walls: \(maze.walls.count)")
        var ball = BallPhysics(maze: maze)
        let R = ball.ballRadius

        func bench(dt: Double, steps: Int) -> (usPerStep: Double, ok: Bool, why: String) {
            ball.reset()
            var ok = true
            var why = ""
            var total: UInt64 = 0
            var t = 0.0
            var hits = 0
            for i in 0..<steps {
                t += dt
                let tilt = Vec2(cos(0.9 * t), sin(0.9 * t))
                let t0 = nowNanos()
                let ev = ball.step(dt: dt, tilt: tilt)
                total += nowNanos() - t0
                hits += ev.filter { if case .wallHit = $0 { return true } else { return false } }.count
                if ball.hasWon { ball.reset() }
                let p = ball.position
                if p.length + R > 1 + 1e-9 { ok = false; why = "left disc at step \(i)"; break }
                let c = clearance(maze, p, ballRadius: R)
                if c < -1e-7 { ok = false; why = "penetration \(fmt(c, 6)) at step \(i) p=\(p)"; break }
            }
            print("  dt=1/\(Int((1 / dt).rounded())): \(fmt(Double(total) / Double(steps) / 1000, 2)) µs/step, \(hits) wallHits")
            return (Double(total) / Double(steps) / 1000, ok, why)
        }

        let r60 = bench(dt: 1.0 / 60, steps: 10_000)
        check(r60.ok, "10k steps @1/60 over \(maze.walls.count) walls: invariants hold", r60.why)
        check(r60.usPerStep < 500, "10k steps @1/60: < 500 µs/step", "\(fmt(r60.usPerStep, 2)) µs")
        let r15 = bench(dt: 1.0 / 15, steps: 10_000)
        check(r15.ok, "10k steps @1/15: invariants hold", r15.why)
        check(r15.usPerStep < 1000, "10k steps @1/15: < 1000 µs/step", "\(fmt(r15.usPerStep, 2)) µs")
    }
}
