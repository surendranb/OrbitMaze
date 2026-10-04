import SwiftUI

/// Full-screen game: HUD strip (level, timer), the maze canvas driven by a
/// TimelineView, and overlays for calibration, countdown, pause and win.
struct GameView: View {
    let session: GameSession

    private static let hudHeight: CGFloat = 24

    private var isTimelinePaused: Bool {
        session.phase == .paused || session.screen != .game
    }

    var body: some View {
        GeometryReader { geo in
            let side = max(40, min(geo.size.width, geo.size.height - Self.hudHeight - 2))
            VStack(spacing: 2) {
                hud
                    .frame(height: Self.hudHeight)
                    .padding(.horizontal, 10)
                ZStack {
                    TimelineView(.animation(paused: isTimelinePaused)) { context in
                        MazeCanvasView(frame: session.renderFrame(), side: side)
                            .onChange(of: context.date) { _, date in
                                session.tick(date)
                            }
                    }
                    // Single taps intentionally do nothing to the game: any tap
                    // or crown turn resets the watchOS 70 s wake timer, so the
                    // user taps to keep the screen on without pausing. Pause is
                    // only via the HUD button (and the pause overlay).
                    .gesture(dragTilt(side: side), including: session.tilt.usesMotion ? .subviews : .all)

                    overlay(side: side)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .ignoresSafeArea(edges: .bottom)
        .background(Color.black)
    }

    // MARK: HUD

    private var hud: some View {
        HStack(spacing: 8) {
            Text("L\(session.level)")
            Spacer()
            Text(TimeFormat.clock(Double(session.elapsedTenths) / 10))
                .monospacedDigit()
            Spacer()
            Button {
                session.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Pause")
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
    }

    // MARK: Simulator / no-motion input

    /// Drag on the maze → tilt vector. Only active when device motion is
    /// unavailable; on a real watch this gesture is never attached.
    private func dragTilt(side: CGFloat) -> some Gesture {
        let range = Double(side) * 0.3   // points of drag for full tilt
        let enabled = !session.tilt.usesMotion
        return DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard enabled else { return }
                let x = Double(value.translation.width) / range
                let y = -Double(value.translation.height) / range   // screen down → maze -y
                session.tilt.manualTilt = Vec2(x, y)
            }
            .onEnded { _ in
                session.tilt.manualTilt = .zero
            }
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlay(side: CGFloat) -> some View {
        switch session.phase {
        case .calibrating:
            Text("Hold still")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .allowsHitTesting(false)

        case .countdown:
            if let digit = session.phase.countdownDigitForDisplay {
                Text("\(digit)")
                    .font(.system(size: side * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.8), radius: 6)
                    .allowsHitTesting(false)
            }

        case .paused:
            PauseOverlay(session: session)

        case .won(let time, let stars):
            WinOverlay(session: session, time: time, stars: stars)

        case .playing:
            EmptyView()
        }
    }
}

private extension GamePhase {
    var countdownDigitForDisplay: Int? {
        if case .countdown(let r) = self { return max(1, Int(r.rounded(.up))) }
        return nil
    }
}
