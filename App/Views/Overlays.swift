import SwiftUI

private let accent = Color(red: 0.25, green: 0.9, blue: 0.75)

/// Shown over the maze when the level is complete. Auto-advances after
/// `autoAdvanceSeconds` unless the user taps Next first.
struct WinOverlay: View {
    let session: GameSession
    let time: Double
    let stars: Int

    private static let autoAdvanceSeconds = 2.5

    var body: some View {
        VStack(spacing: 6) {
            Text(String(repeating: "★", count: stars) + String(repeating: "☆", count: 3 - stars))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(accent)
            Text(TimeFormat.clock(time))
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .monospacedDigit()
            if session.isNewBest {
                Text("Best")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            }
            Button {
                session.nextLevel()
            } label: {
                Text("Next")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.62))
        .task(id: session.level) {
            try? await Task.sleep(for: .seconds(Self.autoAdvanceSeconds))
            if !Task.isCancelled { session.nextLevel() }
        }
    }
}

/// Pause menu. Backed by a dark fill so taps do not reach the maze.
struct PauseOverlay: View {
    let session: GameSession

    var body: some View {
        VStack(spacing: 6) {
            menuButton("Resume", prominent: true) { session.resume() }
            menuButton("Recalibrate") { session.recalibrate() }
            menuButton("Quit") { session.quitToHome() }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.72))
    }

    private func menuButton(_ title: String, prominent: Bool = false, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? accent : .gray)
    }
}
