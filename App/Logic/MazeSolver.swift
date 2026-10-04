// Solution-path length for a generated maze, recovered from its walls.
// Pure Swift (no Foundation) so it type-checks with plain `swiftc`.
//
// Used only to derive the par time of a level (see GameModel.parTime).
// The maze is a perfect maze (a tree), so the path from the start cell to the
// hub is unique and a BFS from the hub gives its length directly.
//
// Cell adjacency is reconstructed geometrically:
//   - cell (r, c) is linked inward to its parent when NO arc wall at radius
//     r·ringWidth covers the cell's mid angle;
//   - cell (r, c) is linked to (r, c+1) when NO radial wall at the boundary
//     angle (c+1)·2π/n spans the ring's mid radius.
// Cell mid angles never coincide with arc end points (ends sit on cell
// boundaries), so no angular tolerance is needed for arcs. Radial angles are
// compared with a small tolerance because 2π wraps to 0.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum MazeSolver {
    /// Number of cells the ball must traverse from its start cell to the hub,
    /// counting the start cell and excluding the hub. Returns 0 if the start
    /// cell is unreachable (cannot happen for a generated maze; defensive).
    public static func solutionLength(of maze: Maze) -> Int {
        let layout = maze.layout
        let rings = layout.ringCount
        let twoPi = 2 * Double.pi

        var offsets: [Int] = []
        var total = 0
        for n in layout.cellsPerRing { offsets.append(total); total += n }

        var arcs: [(radius: Double, start: Double, span: Double)] = []
        var radials: [(angle: Double, inner: Double, outer: Double)] = []
        for wall in maze.walls {
            switch wall {
            case let .arc(radius, start, end):
                var span = end - start
                if span < 0 { span += twoPi }
                arcs.append((radius, normalize(start), span))
            case let .radial(angle, inner, outer):
                radials.append((normalize(angle), min(inner, outer), max(inner, outer)))
            }
        }

        func arcBlocks(radius: Double, theta: Double) -> Bool {
            for a in arcs where abs(a.radius - radius) < 1e-9 {
                if a.span >= twoPi - 1e-9 { return true }
                var rel = theta - a.start
                if rel < 0 { rel += twoPi }
                if rel <= a.span { return true }
            }
            return false
        }

        func radialBlocks(angle: Double, radius: Double) -> Bool {
            for r in radials where r.inner <= radius && radius <= r.outer {
                var d = abs(r.angle - angle)
                if d > Double.pi { d = twoPi - d }
                if d < 1e-7 { return true }
            }
            return false
        }

        // Adjacency.
        var links = [[Int]](repeating: [], count: total)
        func link(_ a: Int, _ b: Int) { links[a].append(b); links[b].append(a) }

        for r in 1...rings {
            let n = layout.cellsPerRing[r]
            let cellAngle = twoPi / Double(n)
            let midRadius = (Double(r) + 0.5) * layout.ringWidth
            let innerRadius = layout.innerRadius(ring: r)
            for c in 0..<n {
                let idx = offsets[r] + c
                let midAngle = (Double(c) + 0.5) * cellAngle
                // Inward link.
                if !arcBlocks(radius: innerRadius, theta: midAngle) {
                    let parent: Int
                    if r == 1 {
                        parent = 0
                    } else {
                        parent = offsets[r - 1] + c * layout.cellsPerRing[r - 1] / n
                    }
                    link(idx, parent)
                }
                // Tangential link to the next cell.
                let boundary = normalize(Double(c + 1) * cellAngle)
                if !radialBlocks(angle: boundary, radius: midRadius) {
                    link(idx, offsets[r] + (c + 1) % n)
                }
            }
        }

        // BFS from the hub.
        var dist = [Int](repeating: -1, count: total)
        dist[0] = 0
        var queue = [0]
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            for v in links[u] where dist[v] < 0 {
                dist[v] = dist[u] + 1
                queue.append(v)
            }
        }

        // Start cell.
        let startRing = min(max(Int(maze.start.length / layout.ringWidth), 1), rings)
        let n = layout.cellsPerRing[startRing]
        let startCell = min(Int(maze.start.angle / (twoPi / Double(n))), n - 1)
        let d = dist[offsets[startRing] + startCell]
        return max(0, d)
    }

    private static func normalize(_ a: Double) -> Double {
        let twoPi = 2 * Double.pi
        var v = a.truncatingRemainder(dividingBy: twoPi)
        if v < 0 { v += twoPi }
        if v >= twoPi - 1e-12 { v = 0 }
        return v
    }
}
