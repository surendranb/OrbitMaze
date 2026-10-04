import SwiftUI

/// One `Canvas` that draws the whole maze: background disc, faint ring
/// guides, glowing goal hub, ball trail, walls (a single stroked path) and the
/// ball. No per-wall views.
///
/// Coordinates: maze frame is centred at the origin with radius 1 and +y UP.
/// Screen frame is y-DOWN, so `point(_:)` flips y. Arcs are given in maze
/// angles (counter-clockwise from +x); on screen their angles are negated.
struct MazeCanvasView: View {
    let frame: RenderFrame
    let side: CGFloat

    private static let background = Color(red: 0.045, green: 0.05, blue: 0.08)
    private static let wall = Color(red: 0.86, green: 0.88, blue: 0.95)
    private static let accent = Color(red: 0.25, green: 0.9, blue: 0.75)
    private static let ball = Color(red: 1.0, green: 0.78, blue: 0.3)

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Wall line width: thickness in maze units × scale, never below 2 pt.
            let provisionalRadius = min(size.width, size.height) / 2
            let lineWidth = max(2, CGFloat(MazeLayout.wallThickness) * provisionalRadius)
            let radius = provisionalRadius - lineWidth / 2 - 1
            guard radius > 10 else { return }

            func point(_ v: Vec2) -> CGPoint {
                CGPoint(x: center.x + CGFloat(v.x) * radius, y: center.y - CGFloat(v.y) * radius)
            }
            func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }

            // 1. Background.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            ctx.fill(circle(center, radius + lineWidth / 2), with: .color(Self.background))

            // 2. Ring guides.
            let ringWidth = radius / CGFloat(frame.ringCount + 1)
            for r in 1...frame.ringCount {
                ctx.stroke(circle(center, ringWidth * CGFloat(r)),
                           with: .color(.white.opacity(0.05)), lineWidth: 1)
            }

            // 3. Goal hub glow. Pulses slowly; brighter once the ball is in.
            let goalR = CGFloat(frame.goalRadius) * radius
            let pulse = 0.5 + 0.5 * sin(frame.clock * 2.2)
            let glowR = goalR * (frame.hasWon ? 2.4 : 1.7 + 0.25 * pulse)
            ctx.fill(circle(center, glowR), with: .radialGradient(
                Gradient(colors: [Self.accent.opacity(frame.hasWon ? 0.55 : 0.35), .clear]),
                center: center, startRadius: 0, endRadius: glowR))
            ctx.fill(circle(center, goalR * 0.55), with: .radialGradient(
                Gradient(colors: [Self.accent.opacity(0.95), Self.accent.opacity(0.35)]),
                center: center, startRadius: 0, endRadius: goalR * 0.55))

            // 4. Trail (oldest → newest, fading in).
            let ballR = max(2.5, CGFloat(frame.ballRadius) * radius)
            let count = frame.trail.count
            if count > 1 {
                for (i, p) in frame.trail.enumerated() {
                    let t = CGFloat(i + 1) / CGFloat(count)
                    let q = point(p)
                    ctx.fill(circle(q, ballR * (0.25 + 0.5 * t)),
                             with: .color(Self.ball.opacity(0.03 + 0.18 * t * t)))
                }
            }

            // 5. Walls — one path, one stroke.
            let walls = Self.cachedWallPath(frame, center: center, radius: radius)
            ctx.stroke(walls, with: .color(Self.wall),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // 6. Ball: soft shadow, body, highlight.
            let b = point(frame.ballPosition)
            ctx.fill(circle(CGPoint(x: b.x + 0.6, y: b.y + 1.2), ballR * 1.05),
                     with: .color(.black.opacity(0.45)))
            ctx.fill(circle(b, ballR), with: .radialGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.7), Self.ball, Color(red: 0.75, green: 0.45, blue: 0.1)]),
                center: CGPoint(x: b.x - ballR * 0.35, y: b.y - ballR * 0.4),
                startRadius: 0, endRadius: ballR * 1.3))
        }
        .frame(width: side, height: side)
    }

    /// Builds the stroked wall geometry in screen space.
    ///
    /// SwiftUI `Path.addArc` takes angles in the y-down screen frame where
    /// `clockwise: false` sweeps with increasing angle (which looks clockwise
    /// on screen). A maze arc runs counter-clockwise (increasing maze angle),
    /// i.e. decreasing screen angle, so it is drawn with `clockwise: true`
    /// from -start to -end. Full circles use `addEllipse` to avoid the flag
    /// entirely.
    /// VERIFY on first run: if walls appear mirrored across ring boundaries
    /// (arcs covering the wrong sectors) flip the `clockwise` flag below.
    /// Walls change once per level, not per frame: build the path once and
    /// reuse it until the level or the canvas geometry changes.
    @MainActor private static var wallCache: (key: UInt64, center: CGPoint, radius: CGFloat, path: Path)?

    @MainActor private static func cachedWallPath(_ frame: RenderFrame, center: CGPoint, radius: CGFloat) -> Path {
        if let c = wallCache, c.key == frame.levelKey, c.center == center, c.radius == radius {
            return c.path
        }
        let path = wallPath(frame.walls, center: center, radius: radius)
        wallCache = (frame.levelKey, center, radius, path)
        return path
    }

    static func wallPath(_ walls: [Wall], center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let twoPi = 2 * Double.pi
        for wall in walls {
            switch wall {
            case let .arc(r, start, end):
                let rr = CGFloat(r) * radius
                var span = end - start
                if span < 0 { span += twoPi }
                if span >= twoPi - 1e-9 || r >= 1.0 - 1e-9 {
                    path.addEllipse(in: CGRect(x: center.x - rr, y: center.y - rr, width: 2 * rr, height: 2 * rr))
                } else {
                    let a0 = Angle(radians: -start)
                    let a1 = Angle(radians: -(start + span))
                    path.move(to: CGPoint(x: center.x + rr * CGFloat(cos(start)),
                                          y: center.y - rr * CGFloat(sin(start))))
                    path.addArc(center: center, radius: rr, startAngle: a0, endAngle: a1, clockwise: true)
                }
            case let .radial(angle, inner, outer):
                let c = CGFloat(cos(angle)), s = CGFloat(sin(angle))
                let i = CGFloat(inner) * radius, o = CGFloat(outer) * radius
                path.move(to: CGPoint(x: center.x + c * i, y: center.y - s * i))
                path.addLine(to: CGPoint(x: center.x + c * o, y: center.y - s * o))
            }
        }
        return path
    }
}
