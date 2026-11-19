import SwiftUI

/// A small capsule showing the YouTube sign-in state.
struct SignInBadge: View {
    let state: SignInState

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(state.color).frame(width: 6, height: 6)
            Text(state.title)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

extension SignInState {
    var title: String {
        switch self {
        case .unknown: "Checking sign-in…"
        case .signedOut: "Signed out"
        case .signedIn: "Signed in"
        case .expired: "Sign-in expired"
        }
    }

    var color: Color {
        switch self {
        case .unknown, .signedOut: .secondary
        case .signedIn: .green
        case .expired: .orange
        }
    }
}
