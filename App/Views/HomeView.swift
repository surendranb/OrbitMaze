import SwiftUI

/// Title screen: Play / Continue, best level, sensitivity, tilt inversion.
struct HomeView: View {
    let session: GameSession

    private static let accent = Color(red: 0.25, green: 0.9, blue: 0.75)

    private var sensitivity: Binding<Sensitivity> {
        Binding(get: { session.sensitivity }, set: { session.setSensitivity($0) })
    }

    private var invertTilt: Binding<Bool> {
        Binding(get: { session.invertTilt }, set: { session.setInvertTilt($0) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    Text("OrbitMaze")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(Self.accent)
                        .padding(.top, 2)

                    Button {
                        session.play()
                    } label: {
                        Text(session.savedLevel > 1 ? "Continue L\(session.savedLevel)" : "Play")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Self.accent.opacity(0.85))

                    if session.savedLevel > 1 {
                        Button {
                            session.newGame()
                        } label: {
                            Text("New game")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Best level \(session.highestLevel)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Picker("Sensitivity", selection: sensitivity) {
                        ForEach(Sensitivity.allCases, id: \.self) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .font(.system(size: 13, design: .rounded))

                    Toggle("Invert tilt", isOn: invertTilt)
                        .font(.system(size: 13, design: .rounded))
                        .tint(Self.accent)
                }
                .padding(.horizontal, 6)
            }
        }
    }
}
