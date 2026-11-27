import SwiftUI

/// Account › Updates: Stow's version and its update, and the yt-dlp Stow keeps current.
struct UpdatesSection: View {
    @Environment(AppUpdater.self) private var updater: AppUpdater?
    @Environment(YtDlpUpdater.self) private var ytdlp: YtDlpUpdater?

    var body: some View {
        Section("Updates") {
            if let updater { StowUpdateRows(updater: updater) }
            if let ytdlp { YtDlpRow(ytdlp: ytdlp) }
        }
    }
}

private struct StowUpdateRows: View {
    let updater: AppUpdater

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if updater.status == .checking { ProgressView().controlSize(.small) }
                if let release = updater.availableRelease {
                    Button("Update and Relaunch") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.installPhase != nil)
                        .help("Download Stow \(release.version.description), replace this copy and open it again")
                } else {
                    Button("Check for Updates") { Task { await updater.checkNow() } }
                        .disabled(updater.status == .checking)
                }
            }
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
        if let phase = updater.installPhase {
            InstallProgress(phase: phase)
        }
        if let error = updater.installError {
            Text(error).font(.callout).foregroundStyle(.red)
        }
        if let release = updater.availableRelease, !release.notes.isEmpty {
            Text(release.notes)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(12)
                .textSelection(.enabled)
        }
    }

    private var version: String { updater.currentVersion.map { "Stow \($0)" } ?? "Stow" }

    private var title: String {
        switch updater.status {
        case .available(let release): "\(version) · Update to \(release.version)"
        case .upToDate: "\(version) · Up to date"
        case .checking: "\(version) · Checking…"
        case .notChecked, .failed: version
        }
    }

    private var detail: String? {
        if case .failed(let message) = updater.status { return message }
        guard let date = updater.lastChecked else { return nil }
        return "Checked \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
    }
}

private struct InstallProgress: View {
    let phase: AppUpdater.InstallPhase

    var body: some View {
        switch phase {
        case .downloading(let fraction?):
            ProgressView(value: fraction) { Text("Downloading… \(Int(fraction * 100))%").font(.callout) }
        case .downloading(nil):
            ProgressView { Text("Downloading…").font(.callout) }.progressViewStyle(.linear)
        case .verifying:
            ProgressView { Text("Checking the download…").font(.callout) }.progressViewStyle(.linear)
        case .installing:
            ProgressView { Text("Installing…").font(.callout) }.progressViewStyle(.linear)
        }
    }
}

private struct YtDlpRow: View {
    let ytdlp: YtDlpUpdater

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if ytdlp.isUpdating { ProgressView().controlSize(.small) }
                Button("Update Now") { Task { await ytdlp.update() } }
                    .disabled(ytdlp.isUpdating)
                    .help("Get yt-dlp's latest release now (Stow also checks once a day)")
            }
        } label: {
            Text(ytdlp.installedVersion.map { "yt-dlp \($0.description)" } ?? "yt-dlp from Homebrew")
            Text(detail)
        }
        if let error = ytdlp.lastError {
            Text(error).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        let checked = ytdlp.lastChecked.map { "checked \($0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" }
        if ytdlp.isUpdating { return "Updating…" }
        let base = ytdlp.installedVersion == nil ? "Stow's own copy isn't installed yet" : "Kept up to date for YouTube changes"
        return [base, checked].compactMap { $0 }.joined(separator: ", ")
    }
}
