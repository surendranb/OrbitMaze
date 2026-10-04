// Shared types for OrbitMaze. Pure Swift (no Foundation) so it compiles on
// macOS with plain `swiftc` and on watchOS inside the app target.
//
// Coordinate system: maze centred at (0,0), outer radius 1.0, +y is UP
// (math convention; the view layer flips y). Angles in radians, measured
// counter-clockwise from +x, normalised to [0, 2π).

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public func dot(_ b: Vec2) -> Double { x * b.x + y * b.y }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec2 { let l = length; return l > 0 ? Vec2(x / l, y / l) : .zero }
    public var angle: Double { let a = atan2(y, x); return a < 0 ? a + 2 * .pi : a }
}

/// A wall the ball collides with. Walls have zero thickness here; the
/// physics treats them as having `MazeLayout.wallThickness`.
public enum Wall: Equatable, Sendable {
    /// Arc of a circle at `radius`, from `start` going counter-clockwise to `end`.
    /// `end` may be < `start` when the arc crosses angle 0. A full circle has
    /// start == 0 and end == 2π.
    case arc(radius: Double, start: Double, end: Double)
    /// Radial segment at `angle`, from `inner` radius to `outer` radius.
    case radial(angle: Double, inner: Double, outer: Double)
}

/// Polar grid layout. Ring 0 is the central goal hub (one cell).
/// Rings 1...ringCount are the maze corridors, ring `ringCount` is outermost.
/// Ring r spans radii [r * ringWidth, (r+1) * ringWidth], ringWidth = 1/(ringCount+1).
public struct MazeLayout: Equatable, Sendable {
    public let ringCount: Int
    /// cellsPerRing[r] = number of cells in ring r. cellsPerRing[0] == 1.
    /// Each ring's count is equal to or exactly double the ring inside it.
    public let cellsPerRing: [Int]
    public static let wallThickness = 0.012

    public init(ringCount: Int, cellsPerRing: [Int]) {
        self.ringCount = ringCount
        self.cellsPerRing = cellsPerRing
    }
    public var ringWidth: Double { 1.0 / Double(ringCount + 1) }
    public func innerRadius(ring: Int) -> Double { Double(ring) * ringWidth }
    public func outerRadius(ring: Int) -> Double { Double(ring + 1) * ringWidth }
}

public struct Maze: Equatable, Sendable {
    public let seed: UInt64
    public let level: Int
    public let layout: MazeLayout
    /// All walls, including the full outer boundary circle at radius 1.0.
    public let walls: [Wall]
    /// Where the ball spawns (centre of a cell in the outermost ring).
    public let start: Vec2
    /// The ball wins when its centre is within this radius of (0,0)
    /// (== ringWidth, i.e. it has entered the hub).
    public let goalRadius: Double

    public init(seed: UInt64, level: Int, layout: MazeLayout, walls: [Wall], start: Vec2, goalRadius: Double) {
        self.seed = seed; self.level = level; self.layout = layout
        self.walls = walls; self.start = start; self.goalRadius = goalRadius
    }
}

/// Deterministic RNG so a seed always rebuilds the same maze.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
