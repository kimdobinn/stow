import StowKit
import SwiftUI
import UIKit

/// A one-line hint on Home that a new version is out; tap for the update sheet, or close it
/// (it stays closed for that version; Settings › About still offers the update).
struct UpdateBanner: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors

    var body: some View {
        if updates.showsBanner, let update = updates.available {
            HStack(spacing: 10) {
                Button {
                    shell.update = update
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title3)
                            .foregroundStyle(colors.accent)
                            .accessibilityHidden(true)
                        Text("Stow \(update.version) is out")
                            .foregroundStyle(colors.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("See what's new")
                            .fontWeight(.semibold)
                            .foregroundStyle(colors.accent)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(Motion.standard) { updates.dismissBanner() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(colors.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide")
            }
            .font(.subheadline)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background(colors.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .motionTransition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// A new version's notes, with "Update in SideStore" (its install link, which asks before it
/// installs) or AltStore's, or the release page when neither is on the phone.
struct UpdateSheet: View {
    let update: AppUpdate
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let link = Updates.link(for: update) { UIApplication.shared.canOpenURL($0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                StowMark(size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stow \(update.version)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.text)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(colors.secondaryText)
                }
            }
            .padding(.bottom, 18)

            Text("What's new")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(colors.secondaryText)
                .padding(.bottom, 6)
            ScrollView {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(colors.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize)

            Text(hint(link.installer))
                .font(.footnote)
                .foregroundStyle(colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack(spacing: 12) {
                Button {
                    updates.dismissBanner()
                    dismiss()
                } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    dismiss()
                    openURL(link.url)
                } label: {
                    Text(buttonTitle(link.installer)).fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, 14)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(colors.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(colors.raised)
    }

    /// "You have 0.1.0 · released 2 days ago".
    private var subtitle: String {
        var parts = ["You have \(updates.currentVersion)"]
        if let date = update.publishedAt {
            let seconds = Date.now.timeIntervalSince(date)
            if seconds >= 0, seconds < 7 * 86_400 {
                // "2 hours ago", "yesterday"
                let ago = Format.ago(date)
                parts.append("released " + ago.prefix(1).lowercased() + ago.dropFirst())
            } else {
                parts.append("released " + date.formatted(.dateTime.month(.abbreviated).day()))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// GitHub's Markdown: inline styles and links, lines as written, list items as bullets.
    private var notes: AttributedString {
        var text = update.notes.isEmpty ? "No notes for this version." : update.notes
        // Markdown's "- item" lines as bullets.
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : String(line)
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func buttonTitle(_ installer: Updates.Installer) -> String {
        switch installer {
        case .sideStore: "Update in SideStore"
        case .altStore: "Update in AltStore"
        case .browser: "Open on GitHub"
        }
    }

    private func hint(_ installer: Updates.Installer) -> String {
        switch installer {
        case .sideStore: "SideStore asks before it installs. It can also update Stow from its own Updates list."
        case .altStore: "AltStore asks before it installs. It can also update Stow from its own Updates list."
        case .browser where update.ipaURL == nil: "This release has no app file, so this opens it on GitHub."
        case .browser: "SideStore isn't on this phone, so this opens the release on GitHub."
        }
    }
}
