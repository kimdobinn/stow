import SwiftUI

/// Sign-in state, Sign in / Sign out, launch at login.
struct AccountTab: View {
    @Environment(AppModel.self) private var model
    @State private var isBusy = false
    @State private var confirmsSignOut = false

    var body: some View {
        Form {
            Section("YouTube") {
                LabeledContent {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView().controlSize(.small)
                        }
                        buttons
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Status")
                        SignInBadge(state: model.signInState)
                    }
                }
                Text("Used for members-only videos and recommendations. The sign-in is kept separate from Safari.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch Stow at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out of YouTube?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) { run(model.signOut) }
        } message: {
            Text("Members-only videos won't be checked until you sign in again.")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.signInState {
        case .signedIn:
            Button("Sign Out") { confirmsSignOut = true }
                .disabled(isBusy)
        case .expired:
            Button("Sign Out") { confirmsSignOut = true }
                .disabled(isBusy)
            Button("Sign In Again") { run(model.signIn) }
                .disabled(isBusy)
        case .signedOut, .unknown:
            Button("Sign in to YouTube") { run(model.signIn) }
                .disabled(isBusy)
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}

#if DEBUG
#Preview {
    AccountTab()
        .environment(AppModel.preview)
        .frame(width: 640, height: 440)
}
#endif
