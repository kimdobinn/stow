import StowKit
import SwiftUI
import UniformTypeIdentifiers

/// What Settings says about the phone's YouTube sign-in (standalone mode).
enum AccountText {
    static func row(_ account: StandaloneAccount, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch account.state {
        case .signedOut:
            return "Not signed in. Optional: for Home, Subscriptions and members-only videos."
        case .expired:
            return "YouTube signed you out. Sign in again."
        case .signedIn:
            var text = "Signed in"
            if let since = account.since {
                let style = Date.FormatStyle(locale: locale, calendar: calendar).day().month(.abbreviated)
                text += " · since " + since.formatted(style)
            }
            if account.source == .file { text += " · from a cookies.txt file" }
            return text
        }
    }

    /// Under "Your channels": "Checked 4 min ago · 23 channels" (when the channels were last read:
    /// a check, a new channel's first fetch or the Mac's channels adopted), errors, that YouTube
    /// couldn't be reached, or that checks are failing.
    static func checkStatus(_ status: CheckStatus, now: Date = .now) -> String {
        if let failing = status.failingMessage { return failing }
        if status.channelCount == 0 { return "Add channels to check them for new videos" }
        if status.isChecking { return "Checking \(Format.count(status.channelCount, "channel"))…" }
        func ago(_ date: Date) -> String {
            let minutes = Int(now.timeIntervalSince(date) / 60)
            return minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : Format.ago(date, now: now).lowercased()
        }
        var parts: [String]
        if status.couldntReachYouTube, let last = status.lastCheck {
            parts = ["Couldn't reach YouTube \(ago(last.finishedAt))", Format.count(status.channelCount, "channel")]
        } else if let read = status.lastReadAt {
            parts = ["Checked \(ago(read))", Format.count(status.channelCount, "channel")]
            if !status.channelErrors.isEmpty {
                parts.append(status.channelErrors.count == 1 ? "1 channel had errors" : "\(status.channelErrors.count) channels had errors")
            }
        } else {
            return "Not checked yet"
        }
        if let until = status.backoffUntil, until > now { parts.append("YouTube asked Stow to slow down") }
        return parts.joined(separator: " · ")
    }
}

/// Settings › YouTube account: sign in (on the web, or with a cookies.txt), sign out, and
/// "Sync watched with YouTube".
struct AccountSection: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @State private var confirmSignOut = false

    var body: some View {
        if let standalone = repository.standalone {
            let account = standalone.accountInfo
            Section {
                AccountRow(text: AccountText.row(account), expired: account.state == .expired, signedIn: account.state != .signedOut)
                switch account.state {
                case .signedOut:
                    Button { shell.signingIn = true } label: { Label("Sign in to YouTube", systemImage: "person.badge.key") }
                    Button { shell.importingCookies = true } label: { Label("Use a cookies.txt file", systemImage: "doc.text") }
                case .signedIn:
                    Toggle(isOn: Binding(get: { standalone.state.syncWatchedWithYouTube }, set: { standalone.setSyncWatched($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync watched with YouTube").foregroundStyle(colors.text)
                            Text(standalone.watchSyncError ?? "Watched here marks it watched on YouTube, and the other way round")
                                .font(.footnote)
                                .foregroundStyle(standalone.watchSyncError == nil ? colors.secondaryText : colors.destructive)
                        }
                    }
                    .tint(.green)
                    Button { shell.importingCookies = true } label: { Label("Use a cookies.txt file", systemImage: "doc.text") }
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right").foregroundStyle(colors.destructive)
                    }
                case .expired:
                    Button { shell.signingIn = true } label: { Label("Sign in again", systemImage: "person.badge.key") }
                    Button { shell.importingCookies = true } label: { Label("Use a cookies.txt file", systemImage: "doc.text") }
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right").foregroundStyle(colors.destructive)
                    }
                }
            } header: {
                Text("YouTube account")
            } footer: {
                Text("Without a sign-in, public channels and videos work as they are. Signing in adds YouTube's Home and Subscriptions, importing your subscriptions, members-only videos and watched sync.")
            }
            .alert("Sign out of YouTube?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) {
                    standalone.signOut()
                    shell.notify("Signed out of YouTube")
                }
            } message: {
                Text("Home and Subscriptions go back to your channels' videos. Downloads stay.")
            }
        }
    }
}

private struct AccountRow: View {
    let text: String
    let expired: Bool
    let signedIn: Bool
    @Environment(\.stowColors) private var colors

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(expired ? Color.red : signedIn ? Color.green : Color.gray)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: expired ? "exclamationmark.triangle.fill" : "person.crop.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(expired ? colors.destructive : colors.text)
        }
        .padding(.vertical, 2)
    }
}

/// Settings › Channels (standalone): the followed channels, the import, and how the checks went.
struct StandaloneChannelsSection: View {
    @Environment(Repository.self) private var repository
    @Environment(\.stowColors) private var colors

    var body: some View {
        if let standalone = repository.standalone {
            Section {
                NavigationLink(value: Route.channelsManage) {
                    Label("Your channels (\(standalone.channels.count))", systemImage: "person.2")
                }
                if standalone.isSignedIn {
                    NavigationLink(value: Route.importChannels) {
                        Label("Import from YouTube", systemImage: "square.and.arrow.down")
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(AccountText.checkStatus(standalone.checkStatus, now: context.date))
                        .font(.footnote)
                        .foregroundStyle(standalone.checkStatus.failingMessage == nil ? colors.secondaryText : colors.destructive)
                }
            } header: {
                Text("Channels")
            } footer: {
                Text("Stow checks your channels about every 15 minutes, and when you pull down to refresh.")
            }
        }
    }
}

/// Settings › YouTube account on its own (the `account` route).
struct AccountScreen: View {
    @Environment(\.stowColors) private var colors

    var body: some View {
        List {
            AccountSection().listRowBackground(colors.raised)
            StandaloneChannelsSection().listRowBackground(colors.raised)
        }
        .scrollContentBackground(.hidden)
        .background(colors.groupedBackground)
        .navigationTitle("YouTube account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "Use a cookies.txt file": what to export, then the file picker. The file itself is only read.
struct CookiesImporter: ViewModifier {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell

    func body(content: Content) -> some View {
        @Bindable var shell = shell
        content.sheet(isPresented: $shell.importingCookies) {
            CookiesFileSheet().sheetTheme(repository)
        }
    }
}

private struct CookiesFileSheet: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var working = false
    @State private var failure: String?

    static let help = "Export cookies.txt for youtube.com from a desktop browser, ideally from a private window you then close, so YouTube doesn't rotate them. Stow keeps only the youtube.com and google.com cookies."

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(Self.help)
                    .font(.body)
                    .foregroundStyle(colors.text)
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(colors.destructive)
                }
                if working {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Checking the sign-in with YouTube…").foregroundStyle(colors.secondaryText)
                    }
                }
                Spacer()
                Button {
                    picking = true
                } label: {
                    Label("Choose cookies.txt", systemImage: "doc.text").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(working)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.background)
            .navigationTitle("Use a cookies.txt file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText, .data]) { result in
                if case .success(let url) = result { importFile(url) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func importFile(_ url: URL) {
        guard let standalone = repository.standalone else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            failure = "Couldn't read that file."
            return
        }
        failure = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await standalone.signIn(cookies: text, source: .file)
                dismiss()
                shell.notify("Signed in to YouTube")
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "YouTube didn't accept this sign-in."
            }
        }
    }
}
