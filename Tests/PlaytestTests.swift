// End-to-end playtest for OrbitMaze. No Foundation, no XCTest.
//
// Proves generated mazes are completable with the real physics by driving the
// ball with a PD bot along the BFS cell path, measures how long levels take,
// and checks the difficulty curve against the human budget and the star
// thresholds (`GameModel.parTime`, linked from App/Logic):
//   - humanlike profile: median ≤ 60 s and p90 ≤ 65 s at every level 1...60,
//     level 1 median ≤ 25 s;
//   - PD bot (.standard): 3★ at every level with margin (p90 ≤ 0.9 × par);
//   - humanlike median earns 1–2★ (never 3★) at every level.
//
// Build & run:
//   swiftc -O -parse-as-library Core/Geometry.swift Core/MazeGenerator.swift \
//       Core/BallPhysics.swift App/Logic/GameModel.swift App/Logic/MazeSolver.swift \
//       Tests/PlaytestTests.swift -o <out> && <out>
//
// Options (argv): `--quick` runs 10 seeds per level instead of 50.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let twoPi = 2 * Double.pi

func fmt(_ x: Double, _ digits: Int = 2) -> String {
    guard x.isFinite else { return "\(x)" }
    let p = pow(10.0, Double(digits))
    let v = (x * p).rounded() / p
    var s = "\(v)"
    // Pad trailing zeros so columns line up ("1.5" -> "1.50").
    if digits > 0 {
        if let dot = s.firstIndex(of: ".") {
            let frac = s.distance(from: dot, to: s.endIndex) - 1
            if frac < digits { s += String(repeating: "0", count: digits - frac) }
        } else {
            s += "." + String(repeating: "0", count: digits)
        }
    }
    return s
}

func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    if s.count >= width { return s }
    let fill = String(repeating: " ", count: width - s.count)
    return right ? fill + s : s + fill
}

func polar(_ r: Double, _ a: Double) -> Vec2 { Vec2(r * cos(a), r * sin(a)) }

func wrapAngle(_ a: Double) -> Double {
    var v = a.truncatingRemainder(dividingBy: twoPi)
    if v < 0 { v += twoPi }
    return v
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    let idx = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[min(max(idx, 0), sorted.count - 1)]
}

// MARK: - Cell graph rebuilt from walls (same approach as MazeTests.swift)

struct WallGraph {
    let maze: Maze
    let layout: MazeLayout
    let offsets: [Int]
    let cellCount: Int
    let eps = 1e-9

    init(maze: Maze) {
        self.maze = maze
        self.layout = maze.layout
        var offsets: [Int] = []
        var total = 0
        for n in layout.cellsPerRing { offsets.append(total); total += n }
        self.offsets = offsets
        self.cellCount = total
    }

    func index(ring: Int, cell: Int) -> Int { offsets[ring] + cell }

    func ring(of index: Int) -> Int {
        var r = layout.ringCount
        while offsets[r] > index { r -= 1 }
        return r
    }

    func cell(of index: Int) -> Int { index - offsets[ring(of: index)] }

    func angleEqual(_ a: Double, _ b: Double) -> Bool {
        let d = abs(a - b).truncatingRemainder(dividingBy: twoPi)
        return d < eps || abs(d - twoPi) < eps
    }

    func arcCovers(start: Double, end: Double, theta: Double) -> Bool {
        if end >= start { return theta >= start - eps && theta <= end + eps }
        return theta >= start - eps || theta <= end + eps
    }

    func blockedInward(ring r: Int, cell c: Int) -> Bool {
        let radius = layout.innerRadius(ring: r)
        let theta = (Double(c) + 0.5) * twoPi / Double(layout.cellsPerRing[r])
        for wall in maze.walls {
            if case let .arc(wr, s, e) = wall, abs(wr - radius) < eps, arcCovers(start: s, end: e, theta: theta) {
                return true
            }
        }
        return false
    }

    func blockedTangential(ring r: Int, cell c: Int) -> Bool {
        let n = layout.cellsPerRing[r]
        let theta = Double((c + 1) % n) * twoPi / Double(n)
        let mid = (Double(r) + 0.5) * layout.ringWidth
        for wall in maze.walls {
            if case let .radial(a, inner, outer) = wall, angleEqual(a, theta), inner <= mid, outer >= mid {
                return true
            }
        }
        return false
    }

    func adjacency() -> [[Int]] {
        var adj = [[Int]](repeating: [], count: cellCount)
        func link(_ a: Int, _ b: Int) { adj[a].append(b); adj[b].append(a) }
        for r in 1...layout.ringCount {
            let n = layout.cellsPerRing[r]
            for c in 0..<n {
                let idx = index(ring: r, cell: c)
                if !blockedInward(ring: r, cell: c) {
                    let parent = r == 1 ? 0 : index(ring: r - 1, cell: c * layout.cellsPerRing[r - 1] / n)
                    link(idx, parent)
                }
                if !blockedTangential(ring: r, cell: c) {
                    link(idx, index(ring: r, cell: (c + 1) % n))
                }
            }
        }
        return adj
    }

    func cellContaining(_ p: Vec2) -> (ring: Int, cell: Int) {
        let r = min(layout.ringCount, Int(p.length / layout.ringWidth))
        let n = layout.cellsPerRing[r]
        let c = min(n - 1, Int(p.angle / (twoPi / Double(n))))
        return (r, c)
    }

    func centre(ring: Int, cell: Int) -> Vec2 {
        if ring == 0 { return .zero }
        let radius = (Double(ring) + 0.5) * layout.ringWidth
        let theta = (Double(cell) + 0.5) * twoPi / Double(layout.cellsPerRing[ring])
        return polar(radius, theta)
    }

    func midAngle(ring: Int, cell: Int) -> Double {
        (Double(cell) + 0.5) * twoPi / Double(layout.cellsPerRing[ring])
    }

    /// BFS path of cell indices from `source` to `target` (inclusive), or [] if unreachable.
    func path(from source: Int, to target: Int, adj: [[Int]]) -> [Int] {
        var prev = [Int](repeating: -1, count: cellCount)
        var seen = [Bool](repeating: false, count: cellCount)
        seen[source] = true
        var queue = [source]
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            if u == target { break }
            for v in adj[u] where !seen[v] { seen[v] = true; prev[v] = u; queue.append(v) }
        }
        guard seen[target] else { return [] }
        var out = [target]
        var cur = target
        while cur != source { cur = prev[cur]; out.append(cur) }
        return out.reversed()
    }

    /// Waypoints for the bot: cell centres, plus the middle of each doorway
    /// (arc gap at the ring boundary for radial moves; the shared cell edge at
    /// mid radius for tangential moves) so the ball goes straight through.
    func waypoints(for path: [Int]) -> [Vec2] {
        var wps: [Vec2] = []
        let w = layout.ringWidth
        for i in 0..<path.count {
            let idx = path[i]
            let r = ring(of: idx), c = cell(of: idx)
            if i > 0 {
                let p = path[i - 1]
                let pr = ring(of: p), pc = cell(of: p)
                if pr != r {
                    // Radial move: gap lives on the outer cell's span at the boundary radius.
                    let outerRing = max(pr, r)
                    let outerCell = pr > r ? pc : c
                    wps.append(polar(Double(outerRing) * w, midAngle(ring: outerRing, cell: outerCell)))
                } else {
                    let n = layout.cellsPerRing[r]
                    let door = (c == (pc + 1) % n) ? Double(c) : Double(pc)
                    wps.append(polar((Double(r) + 0.5) * w, door * twoPi / Double(n)))
                }
            }
            wps.append(centre(ring: r, cell: c))
        }
        return wps
    }
}

// MARK: - Independent wall-distance helper (diagnosis + clearance audit)

/// Distance from `p` to the zero-thickness curve of `wall`.
func distance(_ p: Vec2, to wall: Wall) -> Double {
    switch wall {
    case let .arc(radius, start, end):
        var span = end - start
        if span < 0 { span += twoPi }
        let full = span >= twoPi - 1e-9
        let s0 = wrapAngle(start)
        let rel = wrapAngle(p.angle - s0)
        if full || rel <= span { return abs(p.length - radius) }
        let a = polar(radius, s0), b = polar(radius, s0 + span)
        return min((p - a).length, (p - b).length)
    case let .radial(angle, inner, outer):
        let u = Vec2(cos(angle), sin(angle))
        let t = min(max(p.dot(u), inner), outer)
        return (p - u * t).length
    }
}

func nearestWall(_ maze: Maze, _ p: Vec2) -> (dist: Double, wall: Wall?) {
    var best = Double.infinity
    var which: Wall? = nil
    for w in maze.walls {
        let d = distance(p, to: w)
        if d < best { best = d; which = w }
    }
    return (best, which)
}

// MARK: - Bot

struct BotProfile {
    var name: String
    var kp: Double
    var kd: Double
    var reachFactor: Double     // waypoint reached when within reachFactor × ringWidth
    var tiltCap: Double         // max |tilt| the bot will apply
    var latencyFrames: Int      // tilt applied this many frames after it is computed
    var updateEveryFrames: Int  // control recomputed every N frames (held between)
    var noise: Double           // uniform noise amplitude added to each tilt axis
    var seed: UInt64

    static let bot = BotProfile(name: "bot", kp: 14, kd: 3.0, reachFactor: 0.5, tiltCap: 1.0,
                                latencyFrames: 0, updateEveryFrames: 1, noise: 0, seed: 1)
    /// Aggressive variant: lower damping so it runs near max speed. Lower bound on level time.
    static let fast = BotProfile(name: "fast", kp: 20, kd: 1.4, reachFactor: 0.6, tiltCap: 1.0,
                                 latencyFrames: 0, updateEveryFrames: 1, noise: 0, seed: 3)
    /// Rough stand-in for a human: half tilt authority, 150 ms reaction lag,
    /// 10 Hz decisions, hand jitter. Gains chosen by `--sweep` (100% completion, fewest hits).
    static let human = BotProfile(name: "humanlike", kp: 9, kd: 3.0, reachFactor: 0.5, tiltCap: 0.5,
                                  latencyFrames: 9, updateEveryFrames: 6, noise: 0.15, seed: 7)
}

struct RunResult {
    var completed: Bool
    var time: Double
    var wallHits: Int
    var maxImpact: Double
    var waypointIndex: Int
    var waypointCount: Int
    var lastPosition: Vec2
    var lastVelocity: Vec2
    var trail: [Vec2]
    var waypoints: [Vec2]
    var pathLength: Int
    var stallSeconds: Double
    var replans: Int
    var forks: Int          // cells on the solution path with ≥3 openings (places a player can go wrong)
}

func playMaze(_ maze: Maze, config: PhysicsConfig, profile: BotProfile, timeLimit: Double,
              keepTrail: Bool) -> RunResult {
    let g = WallGraph(maze: maze)
    let adj = g.adjacency()
    let (sr, sc) = g.cellContaining(maze.start)
    var path = g.path(from: g.index(ring: sr, cell: sc), to: 0, adj: adj)
    var wps = g.waypoints(for: path)
    var onPath = [Bool](repeating: false, count: g.cellCount)
    for c in path { onPath[c] = true }
    var replans = 0
    let w = maze.layout.ringWidth
    let reach = profile.reachFactor * w
    let dt = 1.0 / 60.0

    var physics = BallPhysics(maze: maze, config: config)
    var rng = SplitMix64(seed: profile.seed &+ maze.seed &* 31 &+ UInt64(maze.level))
    var tiltQueue = [Vec2](repeating: .zero, count: profile.latencyFrames + 1)
    var heldTilt = Vec2.zero
    var wi = 0
    var t = 0.0
    var hits = 0
    var maxImpact = 0.0
    var trail: [Vec2] = []
    var frame = 0
    var lastAdvance = 0.0
    var worstStall = 0.0

    if path.isEmpty {
        return RunResult(completed: false, time: 0, wallHits: 0, maxImpact: 0, waypointIndex: 0,
                         waypointCount: 0, lastPosition: maze.start, lastVelocity: .zero, trail: [],
                         waypoints: [], pathLength: 0, stallSeconds: 0, replans: 0, forks: 0)
    }
    let pathLength = path.count
    let forks = path.reduce(0) { $0 + (adj[$1].count >= 3 ? 1 : 0) }

    while t < timeLimit && !physics.hasWon {
        let pos = physics.position
        // Re-plan from the ball's actual cell when it has left the path (e.g. clipped
        // a cap and slid into the neighbouring cell) or has made no progress for 1.5 s.
        if frame % 15 == 0 {
            let (cr, cc) = g.cellContaining(pos)
            let here = cr == 0 ? 0 : g.index(ring: cr, cell: cc)
            if !onPath[here] || t - lastAdvance > 1.5 {
                path = g.path(from: here, to: 0, adj: adj)
                wps = g.waypoints(for: path)
                for i in 0..<onPath.count { onPath[i] = false }
                for c in path { onPath[c] = true }
                wi = 0
                lastAdvance = t
                replans += 1
            }
        }
        // Advance waypoints (possibly several in one frame if they are bunched).
        while wi < wps.count - 1 && (wps[wi] - pos).length < reach {
            wi += 1
            lastAdvance = t
        }
        worstStall = max(worstStall, t - lastAdvance)

        if frame % profile.updateEveryFrames == 0 {
            let err = wps[wi] - pos
            var tilt = err * profile.kp - physics.velocity * profile.kd
            if profile.noise > 0 {
                tilt = tilt + Vec2((rng.nextUnitDouble() * 2 - 1) * profile.noise,
                                   (rng.nextUnitDouble() * 2 - 1) * profile.noise)
            }
            let m = tilt.length
            if m > profile.tiltCap { tilt = tilt * (profile.tiltCap / m) }
            heldTilt = tilt
        }
        tiltQueue.append(heldTilt)
        let applied = tiltQueue.removeFirst()

        let events = physics.step(dt: dt, tilt: applied)
        for e in events {
            if case let .wallHit(s) = e { hits += 1; maxImpact = max(maxImpact, s) }
        }
        t += dt
        frame += 1
        if keepTrail && frame % 2 == 0 { trail.append(physics.position) }
    }
    return RunResult(completed: physics.hasWon, time: t, wallHits: hits, maxImpact: maxImpact,
                     waypointIndex: wi, waypointCount: wps.count, lastPosition: physics.position,
                     lastVelocity: physics.velocity, trail: trail, waypoints: wps,
                     pathLength: pathLength, stallSeconds: worstStall, replans: replans, forks: forks)
}

// MARK: - SVG dump with trail

func svgDump(_ maze: Maze, result: RunResult, path: String) {
    let size = 600.0, cx = 300.0, cy = 300.0, scale = 285.0
    func px(_ p: Vec2) -> (Double, Double) { (cx + scale * p.x, cy - scale * p.y) }
    func pxp(_ r: Double, _ theta: Double) -> (Double, Double) { px(polar(r, theta)) }
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(size) \(size)\" width=\"\(size)\" height=\"\(size)\">\n"
    s += "<rect width=\"100%\" height=\"100%\" fill=\"#0b0f1a\"/>\n"
    s += "<circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(scale * maze.goalRadius)\" fill=\"#1f6f3f\" opacity=\"0.6\"/>\n"
    let strokeW = scale * MazeLayout.wallThickness
    s += "<g stroke=\"#e8eefc\" stroke-width=\"\(strokeW)\" fill=\"none\" stroke-linecap=\"round\">\n"
    for wall in maze.walls {
        switch wall {
        case let .arc(radius, start, end):
            var span = end - start
            if span <= 0 { span += twoPi }
            let R = scale * radius
            if span >= twoPi - 1e-9 {
                s += "<circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(R)\"/>\n"
            } else {
                let (x0, y0) = pxp(radius, start)
                let (x1, y1) = pxp(radius, end)
                let large = span > .pi ? 1 : 0
                s += "<path d=\"M \(x0) \(y0) A \(R) \(R) 0 \(large) 0 \(x1) \(y1)\"/>\n"
            }
        case let .radial(angle, inner, outer):
            let (x0, y0) = pxp(inner, angle)
            let (x1, y1) = pxp(outer, angle)
            s += "<line x1=\"\(x0)\" y1=\"\(y0)\" x2=\"\(x1)\" y2=\"\(y1)\"/>\n"
        }
    }
    s += "</g>\n"
    // Planned waypoints.
    s += "<g fill=\"none\" stroke=\"#3a7bd5\" stroke-width=\"1\" stroke-dasharray=\"3 3\">\n<polyline points=\""
    for p in result.waypoints { let (x, y) = px(p); s += "\(x),\(y) " }
    s += "\"/>\n</g>\n"
    for (i, p) in result.waypoints.enumerated() {
        let (x, y) = px(p)
        s += "<circle cx=\"\(x)\" cy=\"\(y)\" r=\"2.5\" fill=\"\(i == result.waypointIndex ? "#ffd166" : "#3a7bd5")\"/>\n"
    }
    // Ball trail.
    if !result.trail.isEmpty {
        s += "<polyline fill=\"none\" stroke=\"#ff5a5f\" stroke-width=\"1.5\" opacity=\"0.85\" points=\""
        for p in result.trail { let (x, y) = px(p); s += "\(x),\(y) " }
        s += "\"/>\n"
    }
    let (sx, sy) = px(maze.start)
    s += "<circle cx=\"\(sx)\" cy=\"\(sy)\" r=\"5\" fill=\"#ff5a5f\"/>\n"
    let (lx, ly) = px(result.lastPosition)
    let ballR = scale * PhysicsConfig.standard.ballRadiusFactor * maze.layout.ringWidth
    s += "<circle cx=\"\(lx)\" cy=\"\(ly)\" r=\"\(ballR)\" fill=\"none\" stroke=\"#ffd166\" stroke-width=\"2\"/>\n"
    s += "<text x=\"8\" y=\"\(size - 8)\" fill=\"#8aa\" font-family=\"monospace\" font-size=\"12\">level \(maze.level) seed \(maze.seed) done=\(result.completed) t=\(fmt(result.time)) wp \(result.waypointIndex)/\(result.waypointCount) hits \(result.wallHits)</text>\n"
    s += "</svg>\n"
    guard let f = fopen(path, "w") else { print("WARN: cannot write \(path)"); return }
    fputs(s, f)
    fclose(f)
}

// MARK: - Analytic opening clearance

struct ClearanceReport {
    var minRadialGap = Double.infinity       // chord across an arc gap minus caps, in ring widths
    var minRadialGapWhere = ""
    var minCorridor = Double.infinity        // ring corridor width minus arc walls, in ring widths
    var minPinch = Double.infinity           // nearest other wall to any doorway corner, minus caps, in ring widths
    var minPinchWhere = ""
    var openings = 0
}

func auditClearance(levels: ClosedRange<Int>, seeds: Int) -> ClearanceReport {
    var rep = ClearanceReport()
    let t = MazeLayout.wallThickness
    for level in levels {
        for s in 0..<seeds {
            let seed = UInt64(s) &* 104_729 &+ 3
            let maze = MazeGenerator.generate(level: level, seed: seed)
            let g = WallGraph(maze: maze)
            let w = maze.layout.ringWidth
            let corridor = (w - t) / w
            if corridor < rep.minCorridor { rep.minCorridor = corridor }
            for r in 1...maze.layout.ringCount {
                let n = maze.layout.cellsPerRing[r]
                let rho = Double(r) * w
                for c in 0..<n where !g.blockedInward(ring: r, cell: c) {
                    rep.openings += 1
                    let th0 = Double(c) * twoPi / Double(n)
                    let th1 = Double(c + 1) * twoPi / Double(n)
                    let p0 = polar(rho, th0), p1 = polar(rho, th1)
                    // A corner is an obstacle if some wall touches it.
                    func touched(_ p: Vec2) -> Bool {
                        for wall in maze.walls where distance(p, to: wall) < 1e-7 { return true }
                        return false
                    }
                    let o0 = touched(p0), o1 = touched(p1)
                    let chord = (p1 - p0).length
                    let gap = chord - (o0 ? t / 2 : 0) - (o1 ? t / 2 : 0)
                    if gap / w < rep.minRadialGap {
                        rep.minRadialGap = gap / w
                        rep.minRadialGapWhere = "L\(level) seed \(seed) ring \(r) cell \(c)"
                    }
                    // Pinch: nearest wall to each walled corner that does not touch that corner.
                    for (p, o) in [(p0, o0), (p1, o1)] where o {
                        var best = Double.infinity
                        for wall in maze.walls {
                            let d = distance(p, to: wall)
                            if d > 1e-7 && d < best { best = d }
                        }
                        let pinch = (best - t) / w
                        if pinch < rep.minPinch {
                            rep.minPinch = pinch
                            rep.minPinchWhere = "L\(level) seed \(seed) ring \(r) cell \(c)"
                        }
                    }
                }
            }
        }
    }
    return rep
}

// MARK: - Main

@main
struct PlaytestTests {
    static let scratch = "/private/tmp/claude-501/-Users-surendran-Documents/ef6cd85a-6a09-496e-b52d-f019064d5b1b/scratchpad"
    static let timeLimit = 120.0
    static let maxLevel = 60

    struct LevelStats {
        var level = 0
        var times: [Double] = []
        var hits: [Int] = []
        var pathLengths: [Int] = []
        var forks: [Int] = []
        var pars: [Double] = []
        var parRatios: [Double] = []      // time / par per completed run
        var scores: [Double] = []
        var failures = 0
        var runs = 0
        var maxStall = 0.0
        var replans = 0

        var sortedTimes: [Double] { times.sorted() }
        var median: Double { percentile(sortedTimes, 0.5) }
        var p90: Double { percentile(sortedTimes, 0.9) }
        var meanPath: Double { Double(pathLengths.reduce(0, +)) / Double(max(1, pathLengths.count)) }
        var meanForks: Double { Double(forks.reduce(0, +)) / Double(max(1, forks.count)) }
        var meanPar: Double { pars.reduce(0, +) / Double(max(1, pars.count)) }
        var meanScore: Double { scores.reduce(0, +) / Double(max(1, scores.count)) }
    }

    static func runSuite(name: String, config: PhysicsConfig, profile: BotProfile,
                         levels: ClosedRange<Int>, seeds: Int, dumpFailures: Bool) -> (failures: Int, stats: [LevelStats]) {
        print("\n== \(name): levels \(levels.lowerBound)-\(levels.upperBound) × \(seeds) seeds, bot=\(profile.name), accel \(config.acceleration) maxSpeed \(config.maxSpeed) ==")
        print(pad("lvl", 4) + pad("rings", 6) + pad("cells", 6) + pad("path", 6) + pad("forks", 6) + pad("done", 8) + pad("median", 8) + pad("p90", 8)
              + pad("max", 8) + pad("par", 7) + pad("t/par", 7) + pad("hits/run", 10) + pad("hits p90", 9) + pad("stall", 7) + pad("replans", 8))
        var totalFailures = 0
        var totalRuns = 0
        var all: [LevelStats] = []
        for level in levels {
            var st = LevelStats()
            st.level = level
            for s in 0..<seeds {
                let seed = UInt64(s) &* 7919 &+ 17 &+ UInt64(level) &* 1000
                let maze = MazeGenerator.generate(level: level, seed: seed)
                var res = playMaze(maze, config: config, profile: profile, timeLimit: timeLimit, keepTrail: false)
                st.runs += 1
                // `pathLength` counts the hub; the solver and the metric do not.
                let solution = MazeSolver.solutionLength(of: maze)
                if solution != res.pathLength - 1 {
                    print("  FAIL \(name) L\(level) seed \(seed): MazeSolver length \(solution) != BFS path \(res.pathLength - 1)")
                    totalFailures += 1
                }
                let par = GameModel.parTime(solutionLength: solution, layout: maze.layout)
                st.pathLengths.append(solution)
                st.forks.append(res.forks)
                st.pars.append(par)
                st.scores.append(MazeGenerator.difficulty(level: level, seed: seed).score)
                st.maxStall = max(st.maxStall, res.stallSeconds)
                st.replans += res.replans
                if res.completed {
                    st.times.append(res.time)
                    st.hits.append(res.wallHits)
                    st.parRatios.append(res.time / par)
                } else {
                    st.failures += 1
                    totalFailures += 1
                    // Re-run with trail for diagnosis.
                    res = playMaze(maze, config: config, profile: profile, timeLimit: timeLimit, keepTrail: true)
                    let near = nearestWall(maze, res.lastPosition)
                    let target = res.waypoints.isEmpty ? Vec2.zero : res.waypoints[res.waypointIndex]
                    print("  FAIL \(name) L\(level) seed \(seed): pos (\(fmt(res.lastPosition.x, 4)), \(fmt(res.lastPosition.y, 4))) r=\(fmt(res.lastPosition.length, 4)) "
                          + "vel \(fmt(res.lastVelocity.length, 4)) waypoint \(res.waypointIndex)/\(res.waypointCount) "
                          + "target (\(fmt(target.x, 4)), \(fmt(target.y, 4))) dist \(fmt((target - res.lastPosition).length, 4)) "
                          + "nearest wall \(fmt(near.dist, 4)) (\(String(describing: near.wall))) hits \(res.wallHits) stall \(fmt(res.stallSeconds, 1))s replans \(res.replans)")
                    if dumpFailures {
                        let path = "\(scratch)/fail_\(name)_L\(level)_seed\(seed).svg"
                        svgDump(maze, result: res, path: path)
                        print("    wrote \(path)")
                    }
                }
            }
            totalRuns += st.runs
            let sorted = st.sortedTimes
            let hitsSorted = st.hits.map(Double.init).sorted()
            let meanHits = st.hits.isEmpty ? 0 : Double(st.hits.reduce(0, +)) / Double(st.hits.count)
            let layout = MazeGenerator.layout(forLevel: level)
            let cells = layout.cellsPerRing.reduce(0, +)
            print(pad("\(level)", 4) + pad("\(layout.ringCount)", 6) + pad("\(cells)", 6) + pad(fmt(st.meanPath, 1), 6) + pad(fmt(st.meanForks, 1), 6)
                  + pad("\(st.runs - st.failures)/\(st.runs)", 8)
                  + pad(fmt(percentile(sorted, 0.5)), 8) + pad(fmt(percentile(sorted, 0.9)), 8)
                  + pad(fmt(sorted.last ?? .nan), 8) + pad(fmt(st.meanPar, 1), 7) + pad(fmt(percentile(st.parRatios.sorted(), 0.5)), 7)
                  + pad(fmt(meanHits, 1), 10)
                  + pad(fmt(percentile(hitsSorted, 0.9), 0), 9) + pad(fmt(st.maxStall, 1), 7) + pad("\(st.replans)", 8))
            all.append(st)
        }
        print("  \(name): \(totalRuns - totalFailures)/\(totalRuns) completed")
        return (totalFailures, all)
    }

    /// Gain sweep for the humanlike profile: prints completion and median time per candidate.
    static func sweep() {
        let levels = [1, 4, 7, 13, 20]
        var candidates: [BotProfile] = []
        for kp in [4.0, 6.0, 9.0, 14.0] {
            for kd in [2.0, 3.0, 4.5] {
                for cap in [0.5, 0.7] {
                    candidates.append(BotProfile(name: "kp\(kp) kd\(kd) cap\(cap)", kp: kp, kd: kd, reachFactor: 0.5,
                                                 tiltCap: cap, latencyFrames: 9, updateEveryFrames: 6, noise: 0.15, seed: 7))
                }
            }
        }
        for prof in candidates {
            var done = 0, runs = 0
            var times: [Double] = []
            var hits = 0
            for level in levels {
                for s in 0..<8 {
                    let seed = UInt64(s) &* 7919 &+ 17 &+ UInt64(level) &* 1000
                    let maze = MazeGenerator.generate(level: level, seed: seed)
                    let r = playMaze(maze, config: .standard, profile: prof, timeLimit: timeLimit, keepTrail: false)
                    runs += 1
                    if r.completed { done += 1; times.append(r.time); hits += r.wallHits }
                }
            }
            let sorted = times.sorted()
            print("  \(pad(prof.name, 24)) done \(done)/\(runs)  median \(fmt(percentile(sorted, 0.5)))  p90 \(fmt(percentile(sorted, 0.9)))  hits/run \(fmt(Double(hits) / Double(max(1, done)), 1))")
        }
    }

    /// Difficulty-curve checks on the standard-bot and humanlike suites
    /// (same mazes: both use the same per-level seeds). Returns failure count.
    static func checkCurve(bot: [LevelStats], human: [LevelStats]) -> Int {
        var failures = 0
        func expect(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("  FAIL curve: \(message)") }
        }
        print("\n== Difficulty curve (standard physics; bot = PD .standard, human = humanlike profile) ==")
        print(pad("lvl", 4) + pad("rings", 6) + pad("path", 6) + pad("forks", 6) + pad("bot50", 7) + pad("hum50", 7) + pad("hum90", 7)
              + pad("par", 7) + pad("bot/par", 8) + pad("hum/par", 8) + pad("hum★", 5) + pad("score", 7))
        let shown = Set(Array(1...20) + [30, 40, 50, 60])
        for (b, h) in zip(bot, human) {
            let level = b.level
            let layout = MazeGenerator.layout(forLevel: level)
            let botRatios = b.parRatios.sorted()
            let humanStars = GameModel.stars(time: h.median, par: h.meanPar)
            if shown.contains(level) {
                print(pad("\(level)", 4) + pad("\(layout.ringCount)", 6) + pad(fmt(b.meanPath, 1), 6) + pad(fmt(b.meanForks, 1), 6)
                      + pad(fmt(b.median, 1), 7) + pad(fmt(h.median, 1), 7) + pad(fmt(h.p90, 1), 7)
                      + pad(fmt(b.meanPar, 1), 7) + pad(fmt(percentile(botRatios, 0.9)), 8) + pad(fmt(h.median / h.meanPar), 8)
                      + pad("\(humanStars)", 5) + pad(fmt(b.meanScore, 1), 7))
            }
            // Human budget.
            expect(h.median <= 60, "L\(level) humanlike median \(fmt(h.median)) s > 60 s")
            expect(h.p90 <= 65, "L\(level) humanlike p90 \(fmt(h.p90)) s > 65 s")
            // Stars: the PD bot gets 3★ with margin on (nearly) every maze; the humanlike median gets 1–2★.
            expect(percentile(botRatios, 0.9) <= 0.9, "L\(level) PD bot p90 time/par \(fmt(percentile(botRatios, 0.9))) > 0.9 (3★ margin too thin)")
            expect((botRatios.last ?? 2) <= 1.0, "L\(level) PD bot misses par on some maze (max t/par \(fmt(botRatios.last ?? .nan)))")
            expect(humanStars >= 1 && humanStars <= 2, "L\(level) humanlike median earns \(humanStars)★ (want 1–2)")
        }
        expect(human[0].median <= 25, "level 1 humanlike median \(fmt(human[0].median)) s > 25 s")
        expect(GameModel.stars(time: human[0].median, par: human[0].meanPar) == 2, "level 1 humanlike median should earn 2★")
        // Humanlike median time trend: later levels take longer (monotone up to noise: compare 5-level blocks).
        var previousBlock = -1.0
        for blockStart in stride(from: 1, through: maxLevel - 4, by: 5) {
            let block = human[(blockStart - 1)..<(blockStart + 4)].map { $0.median }.reduce(0, +) / 5
            expect(block > previousBlock, "humanlike median falls between 5-level blocks at L\(blockStart)")
            previousBlock = block
        }
        print(failures == 0 ? "  curve: PASS" : "  curve: \(failures) failure(s)")
        return failures
    }

    static func main() {
        if CommandLine.arguments.contains("--sweep") { sweep(); return }
        let quick = CommandLine.arguments.contains("--quick")
        let seeds = quick ? 10 : 50
        var failures = 0
        let t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        // 1. Analytic clearance audit.
        print("== Opening clearance audit: levels 1-\(maxLevel) × 100 seeds ==")
        let rep = auditClearance(levels: 1...maxLevel, seeds: 100)
        let ballDia = 2 * PhysicsConfig.standard.ballRadiusFactor   // in ring widths
        print("  openings checked: \(rep.openings)")
        print("  ball diameter: \(fmt(ballDia, 3)) w   (w = ringWidth; 7 rings w = \(fmt(1.0 / 8, 4)))")
        print("  min arc-gap clearance (chord − caps): \(fmt(rep.minRadialGap, 3)) w at \(rep.minRadialGapWhere) → margin \(fmt(rep.minRadialGap - ballDia, 3)) w = \(fmt((rep.minRadialGap - ballDia) / ballDia * 100, 0))% of ball diameter")
        print("  min ring corridor (w − wall): \(fmt(rep.minCorridor, 3)) w → margin \(fmt(rep.minCorridor - ballDia, 3)) w")
        print("  min doorway pinch (nearest non-touching wall − wall): \(fmt(rep.minPinch, 3)) w at \(rep.minPinchWhere) → margin \(fmt(rep.minPinch - ballDia, 3)) w")
        let clearanceOK = rep.minRadialGap > ballDia && rep.minCorridor > ballDia && rep.minPinch > ballDia
        print(clearanceOK ? "  PASS: ball fits through every opening" : "  FAIL: an opening is narrower than the ball")
        if !clearanceOK { failures += 1 }

        // 2. Playtest suites. Standard and humanlike share seeds so the curve
        //    table compares the same mazes.
        let standard = runSuite(name: "standard", config: .standard, profile: .bot, levels: 1...maxLevel, seeds: seeds, dumpFailures: true)
        failures += standard.failures
        failures += runSuite(name: "fast", config: .standard, profile: .fast, levels: 1...maxLevel, seeds: max(5, seeds / 5), dumpFailures: true).failures
        failures += runSuite(name: "low", config: .low, profile: .bot, levels: 1...maxLevel, seeds: max(5, seeds / 5), dumpFailures: true).failures
        failures += runSuite(name: "high", config: .high, profile: .bot, levels: 1...maxLevel, seeds: max(5, seeds / 5), dumpFailures: true).failures
        let human = runSuite(name: "humanlike", config: .standard, profile: .human, levels: 1...maxLevel, seeds: seeds, dumpFailures: true)
        failures += human.failures

        // 3. Difficulty curve: human budget, star thresholds, trend.
        failures += checkCurve(bot: standard.stats, human: human.stats)

        // Sample SVGs of successful runs for visual sanity.
        for level in [1, 10, 30] {
            let seed = UInt64(0) &* 7919 &+ 17 &+ UInt64(level) &* 1000
            let maze = MazeGenerator.generate(level: level, seed: seed)
            let res = playMaze(maze, config: .standard, profile: .bot, timeLimit: timeLimit, keepTrail: true)
            let path = "\(scratch)/playtest_L\(level)_seed\(seed).svg"
            svgDump(maze, result: res, path: path)
            print("  wrote \(path) (done=\(res.completed) t=\(fmt(res.time)) hits=\(res.wallHits))")
        }

        let secs = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / 1e9
        print("\nwall time \(fmt(secs, 1)) s")
        if failures == 0 {
            print("ALL PASSED")
        } else {
            print("FAILURES: \(failures)")
            exit(1)
        }
    }
}
