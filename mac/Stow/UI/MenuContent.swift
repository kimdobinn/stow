import AppKit
import SwiftUI

/// The menu bar panel: status, sign-in state, Inbox and actions.
struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    /// The Inbox scrolls beyond this height.
    private static let maxInboxHeight: CGFloat = 420

    @State private var inboxHeight: CGFloat = 0
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            inbox
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stow").font(.headline)
                CheckStatusLine()
            }
            Spacer()
            SignInBadge(state: model.signInState)
        }
        .padding(12)
    }

    @ViewBuilder
    private var inbox: some View {
        if model.channels.isEmpty {
            VStack(spacing: 8) {
                Text("No channels yet").foregroundStyle(.secondary)
                Button("Add Channels…", action: showSettings)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if model.inbox.isEmpty {
            Text("No new videos")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                inboxHeader
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.inbox) { item in
                            InboxRow(item: item) {
                                openURL(item.video.watchURL)
                            } onDismiss: {
                                model.dismissInbox(videoId: item.id)
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inboxHeight = $0 }
                }
                .frame(height: min(inboxHeight, Self.maxInboxHeight))
            }
            .padding(.bottom, 8)
        }
    }

    /// "Clear All" asks inline first: it can't be undone.
    @ViewBuilder
    private var inboxHeader: some View {
        HStack {
            if confirmsClear {
                Text("Clear \(model.inbox.count) videos?").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Cancel") { confirmsClear = false }
                Button("Clear", role: .destructive) {
                    model.dismissAllInbox()
                    confirmsClear = false
                }
            } else {
                Text("Inbox (\(model.inbox.count))").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { confirmsClear = true }
            }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await model.checkNow() }
            } label: {
                HStack(spacing: 4) {
                    if model.isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Check Now")
                }
            }
            .disabled(model.isChecking)

            Spacer()

            Button("Settings…", action: showSettings)
                .keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
        .padding(12)
    }

    private func showSettings() {
        openWindow(id: SceneID.settings)
        // An LSUIElement app is never frontmost on its own, so the window would open behind others.
        NSApp.activate()
    }
}

#if DEBUG
#Preview {
    MenuContent().environment(AppModel.preview)
}
#endif
