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
            Section("Watched Videos") {
                Toggle(isOn: Binding(
                    get: { model.syncsWatchedWithYouTube },
                    set: { model.setSyncWatchedWithYouTube($0) }
                )) {
                    Text("Sync with YouTube watch history")
                    Text("Videos you watch on YouTube show as watched in Stow, and videos you mark watched in Stow are added to your YouTube history. Checked every 5 minutes.")
                }
                if model.syncsWatchedWithYouTube {
                    WatchSyncStatus()
                }
            }
            Section("General") {
                Toggle("Launch Stow at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
            ScrollingSection()
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

/// "Synced 2 min ago ✓", "Syncing…", or why it can't sync.
private struct WatchSyncStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.everyMinute) { _ in
            HStack(spacing: 6) {
                if model.isSyncingWatched {
                    ProgressView().controlSize(.small)
                    Text("Syncing…")
                } else if model.signInState != .signedIn {
                    Text("Sign in to YouTube to sync.")
                } else if let error = model.watchSyncError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(2).help(error)
                } else if let date = model.lastWatchSync {
                    Text("Synced \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Not synced yet")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
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
