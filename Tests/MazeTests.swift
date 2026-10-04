// Standalone tests for MazeGenerator. No Foundation, no XCTest.
//
// Build & run:
//   swiftc -O -parse-as-library Core/Geometry.swift Core/MazeGenerator.swift \
//       Tests/MazeTests.swift -o <out> && <out>
//
// Covers: layout invariants, determinism, wall geometry, perfect-maze
// property rebuilt from the walls, the start rule (outer cell closest to the
// level's solution-length target), the structural difficulty metric
// (`MazeDifficulty`, cross-checked against the walls) and the difficulty
// curve: seed-averaged score strictly increasing for levels 1...60 and still
// creeping up beyond.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Tiny test harness

struct TestRun {
    var passed = 0
    var failed = 0

    mutating func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition { passed += 1 } else {
            failed += 1
            print("FAIL: \(message())")
            exit(1)
        }
    }

    mutating func section(_ name: String, _ body: (inout TestRun) -> Void) {
        let before = passed
        body(&self)
        print("PASS: \(name) (\(passed - before) checks)")
    }
}

func fmt(_ x: Double, _ digits: Int = 2) -> String {
    guard x.isFinite else { return "\(x)" }
    let p = pow(10.0, Double(digits))
    let v = (x * p).rounded() / p
    var s = "\(v)"
    if digits > 0 {
        if let dot = s.firstIndex(of: ".") {
            let frac = s.distance(from: dot, to: s.endIndex) - 1
            if frac < digits { s += String(repeating: "0", count: digits - frac) }
        } else {
            s += "." + String(repeating: "0", count: digits)
        }
    } else if let dot = s.firstIndex(of: ".") {
        s = String(s[..<dot])
    }
    return s
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: - Connectivity rebuilt from emitted walls

/// Cell graph recovered purely from `Maze.walls` (not from generator internals).
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

    func angleEqual(_ a: Double, _ b: Double) -> Bool {
        let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        return d < eps || abs(d - 2 * .pi) < eps
    }

    func arcCovers(start: Double, end: Double, theta: Double) -> Bool {
        if end >= start { return theta >= start - eps && theta <= end + eps }
        return theta >= start - eps || theta <= end + eps
    }

    /// True when a wall separates ring r cell c from its inward parent.
    func blockedInward(ring r: Int, cell c: Int) -> Bool {
        let radius = layout.innerRadius(ring: r)
        let theta = (Double(c) + 0.5) * 2 * .pi / Double(layout.cellsPerRing[r])
        for wall in maze.walls {
            if case let .arc(wr, s, e) = wall, abs(wr - radius) < eps, arcCovers(start: s, end: e, theta: theta) {
                return true
            }
        }
        return false
    }

    /// True when a wall separates ring r cell c from cell c+1.
    func blockedTangential(ring r: Int, cell c: Int) -> Bool {
        let n = layout.cellsPerRing[r]
        let theta = Double((c + 1) % n) * 2 * .pi / Double(n)
        let mid = (Double(r) + 0.5) * layout.ringWidth
        for wall in maze.walls {
            if case let .radial(a, inner, outer) = wall, angleEqual(a, theta), inner <= mid, outer >= mid {
                return true
            }
        }
        return false
    }

    /// Adjacency from walls. Returns (adjacency, openEdgeCount).
    func adjacency() -> ([[Int]], Int) {
        var adj = [[Int]](repeating: [], count: cellCount)
        var edges = 0
        func link(_ a: Int, _ b: Int) { adj[a].append(b); adj[b].append(a); edges += 1 }
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
        return (adj, edges)
    }

    func cellContaining(_ p: Vec2) -> (ring: Int, cell: Int) {
        let r = min(layout.ringCount, Int(p.length / layout.ringWidth))
        let n = layout.cellsPerRing[r]
        let c = min(n - 1, Int(p.angle / (2 * .pi / Double(n))))
        return (r, c)
    }

    /// BFS distances from `source` over `adj` (-1 = unreachable).
    static func distances(from source: Int, adj: [[Int]]) -> [Int] {
        var dist = [Int](repeating: -1, count: adj.count)
        dist[source] = 0
        var queue = [source]
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            for v in adj[u] where dist[v] < 0 { dist[v] = dist[u] + 1; queue.append(v) }
        }
        return dist
    }

    /// Structural stats of the start → hub path, from the wall graph only:
    /// (solution length, forks, branches, branch depth sum).
    static func pathStats(start: Int, adj: [[Int]], fromHub dist: [Int]) -> (length: Int, forks: Int, branches: Int, depthSum: Int) {
        var onPath = [Bool](repeating: false, count: adj.count)
        var path: [Int] = []
        var u = start
        while u != 0 {
            onPath[u] = true
            path.append(u)
            var next = u
            for v in adj[u] where dist[v] == dist[u] - 1 { next = v; break }
            u = next
        }
        onPath[0] = true
        var forks = 0, branches = 0, depthSum = 0
        for c in path {
            if adj[c].count >= 3 { forks += 1 }
            for v in adj[c] where !onPath[v] {
                branches += 1
                var deepest = 1
                var stack = [(v, c, 1)]
                while let (x, p, d) = stack.popLast() {
                    deepest = max(deepest, d)
                    for y in adj[x] where y != p { stack.append((y, x, d + 1)) }
                }
                depthSum += deepest
            }
        }
        return (path.count, forks, branches, depthSum)
    }
}

// MARK: - SVG dump

func svgDump(_ maze: Maze, path: String) {
    let size = 400.0, cx = 200.0, cy = 200.0, scale = 190.0
    func px(_ r: Double, _ theta: Double) -> (Double, Double) {
        (cx + scale * r * cos(theta), cy - scale * r * sin(theta))
    }
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(size) \(size)\" width=\"\(size)\" height=\"\(size)\">\n"
    s += "<rect width=\"100%\" height=\"100%\" fill=\"#0b0f1a\"/>\n"
    s += "<circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(scale * maze.goalRadius)\" fill=\"#1f6f3f\" opacity=\"0.6\"/>\n"
    s += "<g stroke=\"#e8eefc\" stroke-width=\"3\" fill=\"none\" stroke-linecap=\"round\">\n"
    for wall in maze.walls {
        switch wall {
        case let .arc(radius, start, end):
            var span = end - start
            if span <= 0 { span += 2 * .pi }
            let R = scale * radius
            if span >= 2 * .pi - 1e-9 {
                s += "<circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(R)\"/>\n"
            } else {
                let (x0, y0) = px(radius, start)
                let (x1, y1) = px(radius, end)
                let large = span > .pi ? 1 : 0
                // CCW in math coords == sweep-flag 0 in SVG's y-down frame.
                s += "<path d=\"M \(x0) \(y0) A \(R) \(R) 0 \(large) 0 \(x1) \(y1)\"/>\n"
            }
        case let .radial(angle, inner, outer):
            let (x0, y0) = px(inner, angle)
            let (x1, y1) = px(outer, angle)
            s += "<line x1=\"\(x0)\" y1=\"\(y0)\" x2=\"\(x1)\" y2=\"\(y1)\"/>\n"
        }
    }
    s += "</g>\n"
    let (sx, sy) = (cx + scale * maze.start.x, cy - scale * maze.start.y)
    s += "<circle cx=\"\(sx)\" cy=\"\(sy)\" r=\"6\" fill=\"#ff5a5f\"/>\n"
    let d = MazeGenerator.difficulty(level: maze.level, seed: maze.seed)
    s += "<text x=\"8\" y=\"\(size - 8)\" fill=\"#8aa\" font-family=\"monospace\" font-size=\"12\">level \(maze.level) seed \(maze.seed) rings \(maze.layout.ringCount) path \(d.solutionLength) forks \(d.forks) score \(fmt(d.score, 1))</text>\n"
    s += "</svg>\n"
    guard let f = fopen(path, "w") else { print("WARN: cannot write \(path)"); return }
    fputs(s, f)
    fclose(f)
}

// MARK: - Main

@main
struct MazeTests {
    static let scratch = "/private/tmp/claude-501/-Users-surendran-Documents/ef6cd85a-6a09-496e-b52d-f019064d5b1b/scratchpad"
    static let levels = 1...60
    static let seedsPerLevel = 200
    /// Seeds per level for the curve test. Per-maze score sd is ≤ 4 s-eq, so
    /// the standard error of a level mean is ≤ 0.05 and of a step ≤ 0.07; the
    /// designed per-level increment is ≈ 0.4–0.7 s-eq (≈ 0.5 inside the 7-ring
    /// band), i.e. ≥ 5 σ per step on average. Deterministic seeds.
    static let curveSeeds = 8000

    static func main() {
        var t = TestRun()

        t.section("layout invariants") { t in
            var previousRings = 0
            for level in levels {
                let layout = MazeGenerator.layout(forLevel: level)
                t.check(layout.cellsPerRing.count == layout.ringCount + 1, "L\(level) cellsPerRing length")
                t.check(layout.cellsPerRing[0] == 1, "L\(level) hub has one cell")
                t.check(layout.ringCount >= 3 && layout.ringCount <= MazeGenerator.maxRings, "L\(level) ring cap")
                t.check(layout.ringCount >= previousRings, "L\(level) rings non-decreasing")
                previousRings = layout.ringCount
                for r in 2...layout.ringCount {
                    let a = layout.cellsPerRing[r - 1], b = layout.cellsPerRing[r]
                    t.check(b == a || b == 2 * a, "L\(level) ring \(r) equal-or-double (\(a) -> \(b))")
                    let arc = 2 * .pi * (Double(r) + 0.5) * layout.ringWidth / Double(b)
                    let ratio = arc / layout.ringWidth
                    t.check(ratio >= 1.0 && ratio <= 2.0, "L\(level) ring \(r) arc/width \(ratio)")
                }
            }
            t.check(MazeGenerator.layout(forLevel: 1).ringCount == 3, "level 1 has 3 rings")
            t.check(MazeGenerator.layout(forLevel: 1000).ringCount == MazeGenerator.maxRings, "level 1000 capped")
        }

        t.section("difficulty dials") { t in
            // Every dial moves monotonically with the level, forever, and saturates.
            var previous = MazeGenerator.profile(forLevel: 1)
            t.check(previous.branchShare == 0, "level 1 has no random branching")
            for level in 2...400 {
                let p = MazeGenerator.profile(forLevel: level)
                t.check(p.rings >= previous.rings, "L\(level) rings non-decreasing")
                t.check(p.pathTarget > previous.pathTarget, "L\(level) path target strictly increasing (\(p.pathTarget) vs \(previous.pathTarget))")
                t.check(p.branchShare > previous.branchShare, "L\(level) branch share strictly increasing")
                t.check(p.tangentialWeight >= previous.tangentialWeight, "L\(level) tangential weight non-decreasing")
                t.check(p.pathTarget < MazeGenerator.pathCap, "L\(level) path target under cap")
                t.check(p.branchShare < 1, "L\(level) branch share under 1")
                previous = p
            }
            // The target never asks a ring count for more than its spine can deliver.
            let ceilings = [3: 20.0, 4: 36.0, 5: 48.0, 6: 60.0, 7: 72.0]
            for level in 1...400 {
                let p = MazeGenerator.profile(forLevel: level)
                t.check(p.pathTarget <= ceilings[p.rings]!, "L\(level) target \(p.pathTarget) feasible on \(p.rings) rings")
            }
            t.check(MazeGenerator.pathTarget(forLevel: 1) == MazeGenerator.pathStart, "level 1 target = pathStart")
            t.check(MazeGenerator.profile(forLevel: 0) == MazeGenerator.profile(forLevel: 1), "level 0 clamps to 1")
        }

        t.section("determinism") { t in
            for level in levels {
                var differing = 0
                for s in 0..<seedsPerLevel {
                    let seed = UInt64(s) &* 0x2545_F491_4F6C_DD1D &+ UInt64(level)
                    let a = MazeGenerator.generate(level: level, seed: seed)
                    let b = MazeGenerator.generate(level: level, seed: seed)
                    t.check(a == b, "L\(level) seed \(seed) same seed -> identical maze")
                    let c = MazeGenerator.generate(level: level, seed: seed &+ 1)
                    if a.walls != c.walls { differing += 1 }
                }
                t.check(differing * 100 >= seedsPerLevel * 95, "L\(level) different seeds differ (\(differing)/\(seedsPerLevel))")
            }
            let a = MazeGenerator.generate(level: 5, seed: 42)
            let b = MazeGenerator.generate(level: 6, seed: 42)
            t.check(a.walls != b.walls, "same seed, different level -> different maze")
            t.check(MazeGenerator.difficulty(level: 5, seed: 42) == MazeGenerator.difficulty(level: 5, seed: 42), "difficulty deterministic")
        }

        t.section("wall geometry") { t in
            for level in levels {
                for s in 0..<seedsPerLevel {
                    let maze = MazeGenerator.generate(level: level, seed: UInt64(s) &* 7919 &+ 17)
                    let layout = maze.layout
                    var outerCircle = 0
                    for wall in maze.walls {
                        switch wall {
                        case let .arc(radius, start, end):
                            t.check(!radius.isNaN && !start.isNaN && !end.isNaN, "arc NaN")
                            t.check(radius > 0 && radius <= 1, "arc radius \(radius) in (0,1]")
                            t.check(start >= 0 && start <= 2 * .pi && end >= 0 && end <= 2 * .pi, "arc angles in [0,2π]")
                            t.check(start != end, "arc is not degenerate")
                            let k = radius / layout.ringWidth
                            t.check(abs(k - k.rounded()) < 1e-9, "arc radius \(radius) lies on a ring boundary")
                            if abs(radius - 1) < 1e-12 && start == 0 && end == 2 * .pi { outerCircle += 1 }
                        case let .radial(angle, inner, outer):
                            t.check(!angle.isNaN && !inner.isNaN && !outer.isNaN, "radial NaN")
                            t.check(angle >= 0 && angle <= 2 * .pi, "radial angle in [0,2π]")
                            t.check(inner > 0 && outer <= 1 && inner < outer, "radial radii (0,1], inner<outer")
                            let ki = inner / layout.ringWidth, ko = outer / layout.ringWidth
                            t.check(abs(ki - ki.rounded()) < 1e-9 && abs(ko - ko.rounded()) < 1e-9, "radial radii on ring boundaries")
                            t.check(inner >= layout.ringWidth - 1e-9, "radial walls never enter the hub")
                        }
                    }
                    t.check(outerCircle == 1, "L\(level) exactly one full outer circle (\(outerCircle))")
                    t.check(abs(maze.goalRadius - layout.ringWidth) < 1e-12, "goalRadius == ringWidth")
                    let startR = maze.start.length
                    t.check(startR > layout.innerRadius(ring: layout.ringCount) && startR < 1.0, "L\(level) start inside outermost ring")
                    t.check(maze.level == level, "maze.level set")
                }
            }
        }

        t.section("perfect maze, start rule and metric from walls") { t in
            print("  start rule: outer cell with hub distance closest to the seed's target (ties: most forks)")
            for level in levels {
                var minSolution = Int.max, maxSolution = 0, totalWalls = 0, inWindow = 0
                let profile = MazeGenerator.profile(forLevel: level)
                for s in 0..<seedsPerLevel {
                    let seed = UInt64(s) &* 104_729 &+ 3
                    let maze = MazeGenerator.generate(level: level, seed: seed)
                    let g = WallGraph(maze: maze)
                    let (adj, edges) = g.adjacency()
                    t.check(edges == g.cellCount - 1, "L\(level) seed \(s) spanning tree edge count (\(edges) vs \(g.cellCount - 1))")
                    t.check(adj[0].count == 1, "L\(level) seed \(s) hub has exactly one opening (\(adj[0].count))")
                    let (sr, sc) = g.cellContaining(maze.start)
                    t.check(sr == g.layout.ringCount, "start cell in outermost ring")
                    let startIdx = g.index(ring: sr, cell: sc)
                    let dist = WallGraph.distances(from: startIdx, adj: adj)
                    t.check(!dist.contains(-1), "L\(level) seed \(s) every cell reachable from start")
                    t.check(dist[0] > 0, "L\(level) seed \(s) hub reachable from start")

                    // Start rule, checked against the walls: no outer cell is
                    // closer to this seed's integer target; among equally close
                    // cells none has more forks on its path.
                    let built = MazeGenerator.build(profile: profile, level: level, seed: seed)
                    t.check(built.maze == maze, "build() and generate() agree")
                    let target = built.target
                    t.check(target == Int(profile.pathTarget.rounded(.down)) || target == Int(profile.pathTarget.rounded(.down)) + 1,
                            "L\(level) seed \(s) target \(target) is floor or ceil of \(profile.pathTarget)")
                    let fromHub = WallGraph.distances(from: 0, adj: adj)
                    let outer = g.layout.ringCount
                    let startStats = WallGraph.pathStats(start: startIdx, adj: adj, fromHub: fromHub)
                    t.check(startStats.length == fromHub[startIdx], "path length equals hub distance")
                    let startGap = abs(fromHub[startIdx] - target)
                    for c in 0..<g.layout.cellsPerRing[outer] {
                        let idx = g.index(ring: outer, cell: c)
                        let gap = abs(fromHub[idx] - target)
                        t.check(gap >= startGap, "L\(level) seed \(s) start is closest outer cell to target \(target) (cell \(c) gap \(gap) < \(startGap))")
                        if gap == startGap {
                            let forks = WallGraph.pathStats(start: idx, adj: adj, fromHub: fromHub).forks
                            t.check(forks <= startStats.forks, "L\(level) seed \(s) tie-break by forks (cell \(c): \(forks) > \(startStats.forks))")
                        }
                    }
                    // The spine guarantees an outer cell at target or target + 1, so the
                    // closest cell is never more than 1 off (a tie at target − 1 may win on forks).
                    if abs(fromHub[startIdx] - target) <= 1 { inWindow += 1 }

                    // Metric computed by Core from the tree must match the walls.
                    let d = MazeGenerator.difficulty(level: level, seed: seed)
                    t.check(d.rings == outer, "difficulty rings")
                    t.check(d.solutionLength == startStats.length, "L\(level) seed \(s) metric solution length (\(d.solutionLength) vs \(startStats.length))")
                    t.check(d.forks == startStats.forks, "L\(level) seed \(s) metric forks (\(d.forks) vs \(startStats.forks))")
                    t.check(d.branches == startStats.branches, "L\(level) seed \(s) metric branches (\(d.branches) vs \(startStats.branches))")
                    t.check(d.branchDepthSum == startStats.depthSum, "L\(level) seed \(s) metric depth sum (\(d.branchDepthSum) vs \(startStats.depthSum))")
                    t.check(d.offPathCells == g.cellCount - 1 - startStats.length, "metric off-path cells")
                    let t0 = MazeDifficulty.cellTime(rings: outer)
                    t.check(abs(d.moveTime - (MazeDifficulty.moveBase + Double(d.solutionLength) * t0)) < 1e-9, "metric move time formula")
                    t.check(abs(d.decisionTime - (Double(d.branches) * MazeDifficulty.lookCost + MazeDifficulty.wrongTurnShare * Double(d.branchDepthSum) * t0)) < 1e-9, "metric decision time formula")
                    t.check(d.score > 0 && d.score.isFinite, "metric score finite")

                    minSolution = min(minSolution, dist[0]); maxSolution = max(maxSolution, dist[0])
                    totalWalls += maze.walls.count
                }
                // The spine lands in [target, target + 1] for nearly every seed (4 attempts); a miss falls back to the closest cell.
                t.check(inWindow * 100 >= seedsPerLevel * 99, "L\(level) solution length within 1 of target for ≥ 99 % of seeds (\(inWindow)/\(seedsPerLevel))")
                let layout = MazeGenerator.layout(forLevel: level)
                if level <= 10 || level % 10 == 0 {
                    print("  L\(level): rings \(layout.ringCount) cells \(layout.cellsPerRing) target \(fmt(profile.pathTarget, 1)) solution \(minSolution)...\(maxSolution) steps (\(inWindow)/\(seedsPerLevel) within 1 of target), avg walls \(totalWalls / seedsPerLevel)")
                }
            }
        }

        t.section("difficulty curve") { t in
            // Seed-averaged structural score strictly increases L1 → L60 and
            // keeps creeping up beyond (L60 < L90 < L150 < L300).
            struct Row { var level: Int; var score: Double; var se: Double; var path: Double; var forks: Double; var branches: Double; var depth: Double; var move: Double }
            func row(_ level: Int) -> Row {
                var sum = 0.0, sq = 0.0, path = 0.0, forks = 0.0, branches = 0.0, depth = 0.0, move = 0.0
                for s in 0..<curveSeeds {
                    let seed = UInt64(s) &* 2_654_435_761 &+ 11 &+ UInt64(level) &* 7777
                    let d = MazeGenerator.difficulty(level: level, seed: seed)
                    sum += d.score; sq += d.score * d.score
                    path += Double(d.solutionLength); forks += Double(d.forks); branches += Double(d.branches)
                    depth += Double(d.branchDepthSum); move += d.moveTime
                }
                let n = Double(curveSeeds)
                let mean = sum / n
                let variance = max(0, sq / n - mean * mean)
                return Row(level: level, score: mean, se: (variance / n).squareRoot(), path: path / n, forks: forks / n,
                           branches: branches / n, depth: depth / n, move: move / n)
            }
            print("  " + pad("lvl", 5) + pad("rings", 6) + pad("target", 8) + pad("share", 7) + pad("path", 7) + pad("forks", 7) + pad("brch", 7) + pad("depth", 7) + pad("move", 7) + pad("score", 8) + pad("±se", 6) + pad("Δ", 6) + "z")
            var previous: Row? = nil
            var minZ = Double.infinity
            for level in levels {
                let r = row(level)
                let p = MazeGenerator.profile(forLevel: level)
                var delta = Double.nan, z = Double.nan
                if let q = previous {
                    delta = r.score - q.score
                    z = delta / (r.se * r.se + q.se * q.se).squareRoot()
                    minZ = min(minZ, z)
                    t.check(delta > 0, "L\(level) mean score \(fmt(r.score, 3)) > L\(level - 1) \(fmt(q.score, 3)) (Δ \(fmt(delta, 3)), z \(fmt(z, 1)))")
                }
                t.check(r.se < 0.08, "L\(level) standard error \(fmt(r.se, 3)) small enough to resolve the curve")
                t.check(r.move <= 56, "L\(level) estimated traversal time \(fmt(r.move, 1)) s under the human budget")
                print("  " + pad("\(level)", 5) + pad("\(p.rings)", 6) + pad(fmt(p.pathTarget, 1), 8) + pad(fmt(p.branchShare, 2), 7) + pad(fmt(r.path, 1), 7)
                      + pad(fmt(r.forks, 1), 7) + pad(fmt(r.branches, 1), 7) + pad(fmt(r.depth, 1), 7) + pad(fmt(r.move, 1), 7)
                      + pad(fmt(r.score, 2), 8) + pad(fmt(r.se, 2), 6) + pad(delta.isNaN ? "-" : fmt(delta, 2), 6) + (z.isNaN ? "-" : fmt(z, 1)))
                previous = r
            }
            print("  smallest step z-score L1→L60: \(fmt(minZ, 1))")
            t.check(minZ > 2.5, "every step is at least 2.5 σ above noise (min z \(fmt(minZ, 1)))")
            var last = previous!
            for level in [90, 150, 300] {
                let r = row(level)
                t.check(r.score > last.score, "L\(level) score \(fmt(r.score, 2)) > L\(last.level) \(fmt(last.score, 2)) (still creeping up)")
                t.check(r.move <= 56, "L\(level) estimated traversal time under the human budget")
                print("  L\(level): path \(fmt(r.path, 1)) forks \(fmt(r.forks, 1)) branches \(fmt(r.branches, 1)) move \(fmt(r.move, 1)) score \(fmt(r.score, 2)) ± \(fmt(r.se, 2))")
                last = r
            }
        }

        t.section("performance") { t in
            for _ in 0..<50 { _ = MazeGenerator.generate(level: 60, seed: 1) }   // warm-up
            let iterations = 500
            var worst: UInt64 = 0
            let t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            for i in 0..<iterations {
                let a = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
                _ = MazeGenerator.generate(level: 60, seed: UInt64(i))
                worst = max(worst, clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - a)
            }
            let avgUs = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - t0) / Double(iterations) / 1000
            print("  level 60: avg \(avgUs) µs, worst \(Double(worst) / 1000) µs")
            t.check(avgUs < 1000, "level 60 average under 1 ms (\(avgUs) µs)")
            t.check(worst < 5_000_000, "level 60 worst case under 5 ms")
        }

        for level in [1, 10, 30] {
            let path = "\(scratch)/maze_level\(level).svg"
            svgDump(MazeGenerator.generate(level: level, seed: 2026), path: path)
            print("  wrote \(path)")
        }

        print("ALL PASSED: \(t.passed) checks, \(t.failed) failures")
    }
}
