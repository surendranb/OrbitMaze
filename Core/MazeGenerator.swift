// Procedural circular-maze generator for OrbitMaze.
//
// Pure Swift (no Foundation). Produces a perfect maze (spanning tree) over
// the polar cell grid described by `MazeLayout`, then emits the minimal set
// of merged `Wall`s for the physics layer.
//
// Algorithm summary:
//   1. `profile(forLevel:)` turns the level into four difficulty dials
//      (`DifficultyProfile`): ring count, solution-length target, branch
//      share, tangential weight. `layout(forLevel:)` derives the grid.
//   2. Pick the hub entrance: one random ring-1 cell. The hub is linked to
//      that cell only, so the goal always has exactly one opening.
//   3. Two-phase carve over rings 1...R (the hub is never visited):
//      a. Spine: randomised depth-first walk from the entrance that stops at
//         the first outermost-ring cell whose depth is in
//         [pathTarget, pathTarget + 1]. The stack at that moment is the
//         solution path, so its length is controlled directly. Cells the walk
//         backtracked out of stay carved as dead ends.
//      b. Fill: growing-tree over the remaining cells, frontier = everything
//         carved so far. Each step expands the newest frontier cell
//         (depth-first: few long branches) or, with probability
//         `branchShare`, a uniformly random one (Prim-like: many short
//         branches hanging off the spine). `branchShare` is the forks dial.
//      Neighbour choice in both phases is weighted: same-ring (tangential)
//      moves get `tangentialWeight`, radial moves 1.0.
//   4. Walls: arc pieces on each ring boundary where parent/child cells are
//      not linked, merged into runs; radial pieces between unlinked ring
//      neighbours, merged across contiguous rings at the same angle.
//   5. Start = centre of the outermost-ring cell whose tree distance to the
//      hub is closest to the profile's `pathTarget` (fractional targets are
//      rounded at random per seed, so the seed-averaged length matches the
//      target). Ties go to the candidate whose path passes more branch points.
//      Normally that is the spine's end; if the spine walk exhausted the grid
//      without hitting the window, it is the nearest substitute.
//
// Difficulty curve (see `profile(forLevel:)`): every dial moves in small
// per-level steps and saturates, so the seed-averaged difficulty rises
// strictly from level 1 and keeps creeping up forever, while the solution
// length (hence the time a human needs) stays under a cap.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The per-level dials the generator reads. Pure data; `MazeGenerator.profile`
/// is the level → profile mapping and `generate(profile:level:seed:)` lets
/// tests and tools drive the dials directly.
public struct DifficultyProfile: Equatable, Sendable {
    /// Maze rings (3...`MazeGenerator.maxRings`).
    public var rings: Int
    /// Desired solution length in cells (start cell included, hub excluded).
    /// Fractional: 31.4 means 31 for 60 % of seeds and 32 for 40 %.
    public var pathTarget: Double
    /// Fill phase: probability of expanding a random frontier cell instead of
    /// the newest one. 0 = few long dead ends, 1 = many short branches off the
    /// solution path (more forks).
    public var branchShare: Double
    /// Weight of same-ring moves relative to radial moves when carving.
    public var tangentialWeight: Double

    public init(rings: Int, pathTarget: Double, branchShare: Double, tangentialWeight: Double) {
        self.rings = rings
        self.pathTarget = pathTarget
        self.branchShare = branchShare
        self.tangentialWeight = tangentialWeight
    }
}

public enum MazeGenerator {
    /// Ring count at level 1.
    public static let minRings = 3
    /// Hard cap: a watch screen is ~200pt across, 7 rings leaves ~12pt corridors.
    public static let maxRings = 7
    /// Cells in ring 1 (the ring around the hub).
    public static let innerRingCells = 6

    // MARK: - Difficulty curve

    /// Rings for a level: 3 (L1-2), 4 (L3-8), 5 (L9-16), 6 (L17-27), 7 (L28+).
    /// Each band ends well before `pathTarget` reaches the length the spine
    /// walk can still hit reliably on that ring count (3R ≈ 20, 4R ≈ 36,
    /// 5R ≈ 48, 6R ≈ 60 cells). Adding a ring does not change the time per
    /// cell (measured), it adds off-path cells, i.e. branches.
    public static func ringCount(forLevel level: Int) -> Int {
        let l = max(1, level)
        var rings = minRings
        for threshold in ringThresholds where l >= threshold { rings += 1 }
        return min(rings, maxRings)
    }

    /// Levels at which a ring is added.
    static let ringThresholds = [3, 9, 17, 28]

    /// Solution-length target for a level, in cells (hub excluded):
    ///
    ///     L ≤ 60:  target = 18 + 0.78 · (L − 1)                   (18 → 64)
    ///     L > 60:  target = 64 + (72 − 64) · (1 − exp(−(L − 60) / 40))
    ///
    /// A constant step for the first 60 levels (humanlike ≈ 15 s at level 1,
    /// ≈ 51 s at level 60), then an asymptotic approach to 72 cells (≈ 57 s on
    /// 7 rings: the ~60 s human budget with margin for wrong turns). Strictly
    /// increasing forever; the increment is 0.78 cells up to L60, 0.2 just
    /// after, 0.07 at L100.
    public static func pathTarget(forLevel level: Int) -> Double {
        let l = Double(max(1, level))
        if l <= pathRampLevels {
            return pathStart + pathRampStep * (l - 1)
        }
        let rampEnd = pathStart + pathRampStep * (pathRampLevels - 1)
        return rampEnd + (pathCap - rampEnd) * (1 - exp(-(l - pathRampLevels) / pathTailScale))
    }
    static let pathStart = 18.0
    static let pathRampStep = 0.78
    static let pathRampLevels = 60.0
    static let pathCap = 72.0
    static let pathTailScale = 40.0

    /// Branch share for a level: 0 at level 1 (dead ends are a few long
    /// corridors) rising as `cap · tanh((L − 1) / k)` towards `branchShareCap`
    /// (never reached), so forks on the solution path keep multiplying.
    public static func branchShare(forLevel level: Int) -> Double {
        let l = Double(max(1, level) - 1)
        return branchShareCap * tanh(l / branchShareScale)
    }
    static let branchShareCap = 0.95
    static let branchShareScale = 45.0

    /// Weight of same-ring moves relative to radial moves during carving.
    /// 1.0 at level 1, +0.05 per level, capped at 1.75 (level 16+).
    public static func tangentialWeight(forLevel level: Int) -> Double {
        let l = max(1, level)
        return min(1.75, 1.0 + 0.05 * Double(l - 1))
    }

    /// All dials for a level.
    public static func profile(forLevel level: Int) -> DifficultyProfile {
        DifficultyProfile(rings: ringCount(forLevel: level),
                          pathTarget: pathTarget(forLevel: level),
                          branchShare: branchShare(forLevel: level),
                          tangentialWeight: tangentialWeight(forLevel: level))
    }

    /// Layout for a level. Ring 1 has 6 cells; a ring doubles its count when
    /// the cell arc at the ring's mid radius would exceed 2 × ringWidth
    /// (i.e. when `n < π (r + 0.5)`), which keeps every cell's arc length in
    /// roughly 1.0...2.0 × ringWidth.
    public static func layout(forLevel level: Int) -> MazeLayout {
        layout(rings: ringCount(forLevel: level))
    }

    /// Layout for a ring count (see `layout(forLevel:)`).
    public static func layout(rings: Int) -> MazeLayout {
        let rings = min(max(rings, 1), maxRings)
        var cells = [1]
        var n = innerRingCells
        for r in 1...rings {
            if r > 1, Double(n) < Double.pi * (Double(r) + 0.5) { n *= 2 }
            cells.append(n)
        }
        return MazeLayout(ringCount: rings, cellsPerRing: cells)
    }

    // MARK: - Generation

    /// Deterministic: the same (level, seed) always yields an identical maze.
    public static func generate(level: Int, seed: UInt64) -> Maze {
        let level = max(1, level)
        return generate(profile: profile(forLevel: level), level: level, seed: seed)
    }

    /// Generate with explicit dials. `level` is only folded into the RNG seed
    /// and stamped on the maze.
    public static func generate(profile: DifficultyProfile, level: Int, seed: UInt64) -> Maze {
        build(profile: profile, level: level, seed: seed).maze
    }

    /// Structural difficulty of the maze `generate(level:seed:)` would produce,
    /// computed from the spanning tree directly (no wall parsing).
    public static func difficulty(level: Int, seed: UInt64) -> MazeDifficulty {
        let level = max(1, level)
        return difficulty(profile: profile(forLevel: level), level: level, seed: seed)
    }

    /// `difficulty(level:seed:)` with explicit dials.
    public static func difficulty(profile: DifficultyProfile, level: Int, seed: UInt64) -> MazeDifficulty {
        let built = build(profile: profile, level: level, seed: seed)
        return MazeDifficulty.measure(layout: built.maze.layout, links: built.links, start: built.startCell)
    }

    /// Core of `generate`: the maze plus its tree (adjacency lists), the index
    /// of the start cell and the integer solution-length target drawn for
    /// this seed (tests check the start rule against it).
    static func build(profile: DifficultyProfile, level: Int, seed: UInt64)
        -> (maze: Maze, links: [[Int]], startCell: Int, target: Int) {
        let level = max(1, level)
        let layout = layout(rings: profile.rings)
        let grid = CellGrid(layout: layout)
        var rng = SplitMix64(seed: mix(seed: seed, level: level))

        // Single hub entrance.
        let entrance = grid.index(ring: 1, cell: rng.nextInt(below: layout.cellsPerRing[1]))
        var links = [[Int]](repeating: [], count: grid.cellCount)
        links[grid.hub].append(entrance)
        links[entrance].append(grid.hub)

        // Fractional target → integer per seed, unbiased in expectation.
        let whole = profile.pathTarget.rounded(.down)
        let target = Int(whole) + (rng.nextUnitDouble() < profile.pathTarget - whole ? 1 : 0)

        // Spine: retry a few times when the walk exhausts the grid without
        // landing in the window (rare; see `carveSpine`). Deterministic: the
        // RNG just advances. Keeps the last attempt if all miss.
        let baseLinks = links
        var visited = [Bool](repeating: false, count: grid.cellCount)
        var carved: [Int] = []
        for attempt in 0..<spineAttempts {
            links = baseLinks
            for i in 0..<visited.count { visited[i] = false }
            visited[grid.hub] = true
            visited[entrance] = true
            let spine = carveSpine(grid: grid, from: entrance, target: target, links: &links,
                                   visited: &visited, tangentialWeight: profile.tangentialWeight, rng: &rng)
            carved = spine.order
            if spine.hit || attempt == spineAttempts - 1 { break }
        }
        carveFill(grid: grid, frontier: carved, links: &links, visited: &visited,
                  branchShare: profile.branchShare,
                  tangentialWeight: profile.tangentialWeight, rng: &rng)

        let walls = emitWalls(grid: grid, links: links)
        let startCell = chooseStart(grid: grid, links: links, target: target)
        let start = grid.cellCentre(ring: layout.ringCount, cell: startCell)
        let maze = Maze(seed: seed, level: level, layout: layout, walls: walls,
                        start: start, goalRadius: layout.ringWidth)
        return (maze, links, grid.index(ring: layout.ringCount, cell: startCell), target)
    }

    /// Spine walk attempts before accepting a miss.
    static let spineAttempts = 4

    /// Folds the level into the seed so adjacent levels with the same seed differ.
    static func mix(seed: UInt64, level: Int) -> UInt64 {
        var z = seed ^ (UInt64(level) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 32)) &* 0xD6E8_FEB8_6659_FD93
        return z ^ (z >> 32)
    }

    /// Picks one unvisited neighbour of `cell` in a ring ≥ `minRing`,
    /// tangential moves weighted by `tangentialWeight`. Nil when there is none.
    @inline(__always)
    static func pickNeighbour(grid: CellGrid, of cell: Int, visited: [Bool], minRing: Int,
                              tangentialWeight: Double, rng: inout SplitMix64) -> Int? {
        let ring = grid.ring(of: cell)
        var cells = (0, 0, 0, 0)
        var weights = (0.0, 0.0, 0.0, 0.0)
        var count = 0
        var total = 0.0
        grid.forEachNeighbour(of: cell) { neighbour, tangential in
            guard !visited[neighbour] else { return }
            // Tangential = same ring; radial = parent (ring-1) or child (ring+1).
            let neighbourRing = tangential ? ring : (neighbour < cell ? ring - 1 : ring + 1)
            guard neighbourRing >= minRing else { return }
            let w = tangential ? tangentialWeight : 1.0
            switch count {
            case 0: cells.0 = neighbour; weights.0 = w
            case 1: cells.1 = neighbour; weights.1 = w
            case 2: cells.2 = neighbour; weights.2 = w
            default: cells.3 = neighbour; weights.3 = w
            }
            count += 1
            total += w
        }
        guard count > 0 else { return nil }
        var roll = rng.nextUnitDouble() * total
        roll -= weights.0; if roll < 0 || count == 1 { return cells.0 }
        roll -= weights.1; if roll < 0 || count == 2 { return cells.1 }
        roll -= weights.2; if roll < 0 || count == 3 { return cells.2 }
        return cells.3
    }

    /// Phase 1: randomised depth-first walk from `root`. Stops at the first
    /// outermost-ring cell whose depth (cells from `root`, inclusive) lies in
    /// `target...target + 1`; the stack is then the solution path. The walk
    /// never steps to a cell from which the outer ring is out of reach within
    /// the remaining budget (`ring ≥ R − (target − depth)`), and backtracks
    /// when no such step exists, so it lands in the window for almost every
    /// seed. If it exhausts the grid anyway (`hit == false`, the caller
    /// retries) the carved part is a plain depth-first tree. Returns every cell carved, in visitation order (the fill
    /// frontier), and whether the window was hit.
    static func carveSpine(grid: CellGrid, from root: Int, target: Int, links: inout [[Int]],
                           visited: inout [Bool], tangentialWeight: Double,
                           rng: inout SplitMix64) -> (order: [Int], hit: Bool) {
        let outerRing = grid.layout.ringCount
        let outerStart = grid.offsets[outerRing]
        var stack = [root]
        stack.reserveCapacity(grid.cellCount)
        var order = [root]
        order.reserveCapacity(grid.cellCount)

        var hit = false
        while let current = stack.last {
            if current >= outerStart, stack.count >= target, stack.count <= target + 1 { hit = true; break }
            let minRing = outerRing - (target - stack.count)
            guard let next = pickNeighbour(grid: grid, of: current, visited: visited, minRing: minRing,
                                           tangentialWeight: tangentialWeight, rng: &rng) else {
                stack.removeLast()
                continue
            }
            visited[next] = true
            links[current].append(next)
            links[next].append(current)
            stack.append(next)
            order.append(next)
        }
        return (order, hit)
    }

    /// Phase 2: growing-tree over the unvisited cells. Each step expands the
    /// newest frontier cell or, with probability `branchShare`, a uniformly
    /// random one, and drops cells with no unvisited neighbours.
    static func carveFill(grid: CellGrid, frontier initial: [Int], links: inout [[Int]],
                          visited: inout [Bool], branchShare: Double, tangentialWeight: Double,
                          rng: inout SplitMix64) {
        var frontier = initial
        frontier.reserveCapacity(grid.cellCount)
        while !frontier.isEmpty {
            let pick: Int
            if branchShare > 0, rng.nextUnitDouble() < branchShare {
                pick = rng.nextInt(below: frontier.count)
            } else {
                pick = frontier.count - 1
            }
            let current = frontier[pick]
            guard let next = pickNeighbour(grid: grid, of: current, visited: visited, minRing: 0,
                                           tangentialWeight: tangentialWeight, rng: &rng) else {
                frontier.remove(at: pick)
                continue
            }
            visited[next] = true
            links[current].append(next)
            links[next].append(current)
            frontier.append(next)
        }
    }

    // MARK: - Walls

    static func emitWalls(grid: CellGrid, links: [[Int]]) -> [Wall] {
        let layout = grid.layout
        let rings = layout.ringCount
        let nMax = layout.cellsPerRing[rings]
        func angle(k: Int) -> Double { 2 * .pi * Double(k) / Double(nMax) }

        var walls: [Wall] = []

        // Arc walls on each inner ring boundary (radius r * ringWidth).
        for r in 1...rings {
            let n = layout.cellsPerRing[r]
            let stride = nMax / n
            var blocked = [Bool](repeating: false, count: n)
            for c in 0..<n {
                let idx = grid.index(ring: r, cell: c)
                blocked[c] = !links[idx].contains(grid.parent(of: idx))
            }
            let radius = layout.innerRadius(ring: r)
            walls.append(contentsOf: mergedArcs(radius: radius, blocked: blocked,
                                                stride: stride, nMax: nMax, angle: angle))
        }

        // Outer boundary: a full circle.
        walls.append(.arc(radius: 1.0, start: 0, end: 2 * .pi))

        // Radial walls between unlinked same-ring neighbours, grouped by
        // boundary angle (as integer k of 2π/nMax) and merged across rings.
        var radialRings = [[Int]](repeating: [], count: nMax)
        for r in 1...rings {
            let n = layout.cellsPerRing[r]
            let stride = nMax / n
            for c in 0..<n {
                let idx = grid.index(ring: r, cell: c)
                let next = grid.index(ring: r, cell: (c + 1) % n)
                if !links[idx].contains(next) {
                    radialRings[((c + 1) % n) * stride].append(r)
                }
            }
        }
        for k in 0..<nMax where !radialRings[k].isEmpty {
            let rs = radialRings[k]   // already ascending (rings visited in order)
            var runStart = rs[0]
            var runEnd = rs[0]
            for r in rs.dropFirst() {
                if r == runEnd + 1 { runEnd = r; continue }
                walls.append(.radial(angle: angle(k: k), inner: layout.innerRadius(ring: runStart),
                                     outer: layout.outerRadius(ring: runEnd)))
                runStart = r; runEnd = r
            }
            walls.append(.radial(angle: angle(k: k), inner: layout.innerRadius(ring: runStart),
                                 outer: layout.outerRadius(ring: runEnd)))
        }
        return walls
    }

    /// Merges contiguous blocked cells on one ring boundary into single arcs.
    static func mergedArcs(radius: Double, blocked: [Bool], stride: Int, nMax: Int,
                           angle: (Int) -> Double) -> [Wall] {
        let n = blocked.count
        let blockedCount = blocked.reduce(0) { $0 + ($1 ? 1 : 0) }
        if blockedCount == 0 { return [] }
        if blockedCount == n { return [.arc(radius: radius, start: 0, end: 2 * .pi)] }

        // Rotate so the scan starts at the beginning of a blocked run.
        var first = 0
        while !(blocked[first] && !blocked[(first + n - 1) % n]) { first += 1 }

        var arcs: [Wall] = []
        var i = 0
        while i < n {
            let c = (first + i) % n
            guard blocked[c] else { i += 1; continue }
            var len = 1
            while i + len < n && blocked[(first + i + len) % n] { len += 1 }
            let startK = c * stride
            let endK = (c + len) * stride
            let end = endK == nMax ? 2 * Double.pi : angle(endK % nMax)
            arcs.append(.arc(radius: radius, start: angle(startK), end: end))
            i += len
        }
        return arcs
    }

    // MARK: - Start

    /// BFS tree distances from the hub (hub = 0).
    static func hubDistances(grid: CellGrid, links: [[Int]]) -> [Int] {
        var dist = [Int](repeating: -1, count: grid.cellCount)
        dist[grid.hub] = 0
        var queue = [grid.hub]
        queue.reserveCapacity(grid.cellCount)
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            for v in links[u] where dist[v] < 0 {
                dist[v] = dist[u] + 1
                queue.append(v)
            }
        }
        return dist
    }

    /// Outermost-ring cell whose tree distance to the hub is closest to
    /// `target`. Ties: the candidate whose path has more branch points
    /// (cells with ≥ 3 openings), then the lowest cell index.
    static func chooseStart(grid: CellGrid, links: [[Int]], target: Int) -> Int {
        let dist = hubDistances(grid: grid, links: links)
        let outer = grid.layout.ringCount
        let n = grid.layout.cellsPerRing[outer]

        var bestGap = Int.max
        var tied: [Int] = []
        for c in 0..<n {
            let gap = abs(dist[grid.index(ring: outer, cell: c)] - target)
            if gap < bestGap { bestGap = gap; tied = [c] } else if gap == bestGap { tied.append(c) }
        }
        if tied.count == 1 { return tied[0] }

        var best = tied[0]
        var bestForks = -1
        for c in tied {
            let forks = forksOnPath(from: grid.index(ring: outer, cell: c), links: links, dist: dist)
            if forks > bestForks { bestForks = forks; best = c }
        }
        return best
    }

    /// Cells with ≥ 3 openings on the tree path from `cell` to the hub.
    static func forksOnPath(from cell: Int, links: [[Int]], dist: [Int]) -> Int {
        var forks = 0
        var u = cell
        while dist[u] > 0 {
            if links[u].count >= 3 { forks += 1 }
            // Parent = the neighbour one step closer to the hub (unique in a tree).
            var next = u
            for v in links[u] where dist[v] == dist[u] - 1 { next = v; break }
            u = next
        }
        return forks
    }
}

// MARK: - Difficulty metric

/// Structural difficulty of one maze, in "human seconds": an estimate of how
/// long a person needs, built from two parts.
///
///   moveTime     = 0.64 + L · tCell,   tCell = 0.689 + 0.394 · ringWidth
///                  Time to roll along the solution (L cells). Fitted to the
///                  playtest's humanlike bot (half tilt, 150 ms lag, 10 Hz,
///                  jitter), which follows the optimal path: rmse 1.6 s over
///                  3...7 rings and 12...80 cells. [Fact: measured.]
///   decisionTime = Σ over dead-end branches b that hang off the solution
///                  path of (0.5 + 0.5 · depth(b) · tCell)
///                  Every branch is a place to go wrong: half a second to look,
///                  plus a 25 % chance of walking into it and back
///                  (2 · 0.25 · depth cells). [Hypothesis: a wrong-turn model;
///                  the weights are assumptions, not measurements.]
///   score        = moveTime + decisionTime
///
/// `moveTime` is what the playtest clocks; `decisionTime` is what makes two
/// mazes with the same path length differ. Seed-averaged, `score` rises
/// strictly with the level (see Tests/MazeTests.swift "difficulty curve").
public struct MazeDifficulty: Equatable, Sendable {
    public var rings: Int
    /// Cells on the solution path, start included, hub excluded.
    public var solutionLength: Int
    /// Solution-path cells with ≥ 3 openings.
    public var forks: Int
    /// Off-path subtrees rooted at a solution-path cell (wrong turns offered).
    public var branches: Int
    /// Sum over branches of their depth (longest corridor into the dead end).
    public var branchDepthSum: Int
    /// Cells not on the solution path.
    public var offPathCells: Int
    public var moveTime: Double
    public var decisionTime: Double
    public var score: Double { moveTime + decisionTime }

    public static let moveBase = 0.64
    public static let cellTimeBase = 0.689
    public static let cellTimePerRingWidth = 0.394
    public static let lookCost = 0.5
    public static let wrongTurnShare = 0.5

    /// Seconds per solution cell for a ring count (humanlike bot fit).
    public static func cellTime(rings: Int) -> Double {
        cellTimeBase + cellTimePerRingWidth / Double(rings + 1)
    }

    /// The score formula on raw counts (pure; tests and tools use it too).
    public init(rings: Int, solutionLength: Int, forks: Int, branches: Int,
                branchDepthSum: Int, offPathCells: Int) {
        self.rings = rings
        self.solutionLength = solutionLength
        self.forks = forks
        self.branches = branches
        self.branchDepthSum = branchDepthSum
        self.offPathCells = offPathCells
        let t = Self.cellTime(rings: rings)
        moveTime = Self.moveBase + Double(solutionLength) * t
        decisionTime = Double(branches) * Self.lookCost + Self.wrongTurnShare * Double(branchDepthSum) * t
    }

    /// Measures a spanning tree given as adjacency lists (`links[hub] = [entrance]`).
    static func measure(layout: MazeLayout, links: [[Int]], start: Int) -> MazeDifficulty {
        let n = links.count
        // Path start → hub: walk parents using hub distances.
        var dist = [Int](repeating: -1, count: n)
        dist[0] = 0
        var queue = [0]
        queue.reserveCapacity(n)
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            for v in links[u] where dist[v] < 0 { dist[v] = dist[u] + 1; queue.append(v) }
        }
        var onPath = [Bool](repeating: false, count: n)
        var path: [Int] = []
        var u = start
        while u != 0 {
            onPath[u] = true
            path.append(u)
            var next = u
            for v in links[u] where dist[v] == dist[u] - 1 { next = v; break }
            u = next
        }
        onPath[0] = true

        var forks = 0, branches = 0, depthSum = 0
        var stack: [(cell: Int, parent: Int, depth: Int)] = []
        for c in path {
            if links[c].count >= 3 { forks += 1 }
            for v in links[c] where !onPath[v] {
                branches += 1
                var deepest = 1
                stack.removeAll(keepingCapacity: true)
                stack.append((v, c, 1))
                while let (x, p, d) = stack.popLast() {
                    if d > deepest { deepest = d }
                    for y in links[x] where y != p { stack.append((y, x, d + 1)) }
                }
                depthSum += deepest
            }
        }
        return MazeDifficulty(rings: layout.ringCount, solutionLength: path.count, forks: forks,
                              branches: branches, branchDepthSum: depthSum,
                              offPathCells: n - 1 - path.count)
    }
}

// MARK: - Cell grid

/// Index space and adjacency for the polar grid. Cell 0 is the hub; ring r's
/// cells are contiguous starting at `offsets[r]`.
struct CellGrid {
    let layout: MazeLayout
    let offsets: [Int]
    let cellCount: Int
    var hub: Int { 0 }

    init(layout: MazeLayout) {
        self.layout = layout
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

    /// Inward neighbour (ring r-1). Ring 1's parent is the hub.
    func parent(of index: Int) -> Int {
        let r = ring(of: index)
        if r == 1 { return hub }
        let c = index - offsets[r]
        return offsets[r - 1] + c * layout.cellsPerRing[r - 1] / layout.cellsPerRing[r]
    }

    /// Calls `body(neighbour, isTangential)` for each neighbour of a non-hub
    /// cell, hub excluded (the hub is linked separately).
    func forEachNeighbour(of index: Int, _ body: (Int, Bool) -> Void) {
        let r = ring(of: index)
        let n = layout.cellsPerRing[r]
        let c = index - offsets[r]
        body(offsets[r] + (c + 1) % n, true)
        body(offsets[r] + (c + n - 1) % n, true)
        if r > 1 { body(parent(of: index), false) }
        if r < layout.ringCount {
            let nOut = layout.cellsPerRing[r + 1]
            if nOut == n {
                body(offsets[r + 1] + c, false)
            } else {
                body(offsets[r + 1] + 2 * c, false)
                body(offsets[r + 1] + 2 * c + 1, false)
            }
        }
    }

    func cellCentre(ring: Int, cell: Int) -> Vec2 {
        let radius = (Double(ring) + 0.5) * layout.ringWidth
        let theta = (Double(cell) + 0.5) * 2 * .pi / Double(layout.cellsPerRing[ring])
        return Vec2(radius * cos(theta), radius * sin(theta))
    }
}

// MARK: - RNG helpers

extension SplitMix64 {
    /// Uniform integer in 0..<n (n > 0).
    mutating func nextInt(below n: Int) -> Int { Int(next() % UInt64(n)) }
    /// Uniform double in [0, 1).
    mutating func nextUnitDouble() -> Double { Double(next() >> 11) * 0x1p-53 }
}
