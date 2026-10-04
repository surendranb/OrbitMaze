import SwiftUI

@main
struct OrbitMazeApp: App {
    @State private var session = GameSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .onChange(of: scenePhase) { _, phase in
                    // Wrist-down, Digital Crown press, notifications: the game
                    // cannot be played blind, so pause and wait for the user.
                    if phase != .active { session.appBecameInactive() }
                }
                #if DEBUG
                // Screenshot/testing hook: `simctl launch <device> <bundle> -autoplay`
                // jumps straight into the saved level (add `-currentLevel N` to pick one).
                .task {
                    if CommandLine.arguments.contains("-autoplay") { session.play() }
                }
                #endif
        }
    }
}

/// Switches between the Home and Game screens. No NavigationStack for the
/// game itself: it owns the full screen.
struct RootView: View {
    let session: GameSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch session.screen {
            case .home:
                HomeView(session: session)
                    .transition(.opacity)
            case .game:
                GameView(session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.screen)
    }
}
