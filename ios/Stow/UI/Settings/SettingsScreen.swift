import StowKit
import SwiftUI

/// Look, watching, downloads, the downloader and the Mac, as rows in iOS Settings' style.
struct SettingsScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.stowColors) private var colors
    @State private var storage: Int64?
    @State private var ytDlpVersion: String?
    @State private var confirmUnpair = false
    @State private var confirmDeleteWatched = false
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var prefs = repository.prefs
        ScrollViewReader { proxy in
        List {
            Section("Appearance") {
                ThemePicker(selected: prefs.theme) { theme in
                    withAnimation(.snappy) { prefs.theme = theme }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
            }
            .listRowBackground(colors.raised)

            Section("Watching") {
                NavigationLink(value: Route.report) {
                    SettingLabel("Your week", "Time watched per day and channel", icon: "chart.bar.fill", color: .purple)
                }
                NavigationLink(value: Route.groups) {
                    SettingLabel("Channel groups", repository.groups.isEmpty ? "Home can show just the channels you pick"
                                                                              : Format.count(repository.groups.count, "group"),
                                 icon: "folder.fill", color: .orange)
                }
                Toggle(isOn: $prefs.autoplay) {
                    SettingLabel("Autoplay next video", prefs.autoplay ? "Plays the next video in the list" : "Stops at the end of each video",
                                 icon: "play.fill", color: .blue)
                }
                Toggle(isOn: $prefs.calm) {
                    SettingLabel("Calm mode", "Titles only, no thumbnails", icon: "text.alignleft", color: .teal)
                }
                Toggle(isOn: $prefs.grayscale) {
                    SettingLabel("Black and white", "The app in grayscale (videos stay in color)",
                                 icon: "circle.lefthalf.filled", color: .gray)
                }
            }
            .toggleStyle(.switch)
            .tint(.green)
            .listRowBackground(colors.raised)

            Section {
                Toggle(isOn: Binding(get: { prefs.wifiOnly }, set: { repository.setWifiOnly($0) })) {
                    SettingLabel("Download on Wi-Fi only", prefs.wifiOnly ? "Waits for Wi-Fi" : "Also uses mobile data",
                                 icon: "wifi", color: .blue)
                }
                .tint(.green)
                NavigationLink {
                    QualityScreen()
                } label: {
                    LabeledContent {
                        Text(prefs.downloadQuality.label)
                    } label: {
                        SettingLabel("Quality", "The highest a download takes", icon: "film", color: .purple)
                    }
                }
                .id("downloads")
                LabeledContent {
                    Text(storage.map(Format.bytes) ?? "…")
                } label: {
                    SettingLabel("Storage used", "Downloads on this phone", icon: "internaldrive.fill", color: .gray)
                }
                Button { confirmDeleteWatched = true } label: {
                    SettingLabel("Delete watched downloads", "Frees space; videos stay in your lists", icon: "trash.fill", color: .orange)
                }
                .disabled(watchedDownloads.isEmpty)
                Button { confirmDeleteAll = true } label: {
                    SettingLabel("Delete all downloads", "Every video on this phone, watched or not",
                                 icon: "trash.fill", color: .red, destructive: true)
                }
                .disabled(repository.downloadIds().isEmpty)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Videos download only when you tap the download button, here or with Send to Phone on the Mac.")
            }
            .listRowBackground(colors.raised)

            Section {
                NavigationLink(value: Route.ytdlp) {
                    SettingLabel("yt-dlp", "Version \(ytDlpVersion ?? "…") · updates with the app",
                                 icon: "arrow.down.app.fill", color: .green)
                }
            } header: {
                Text("Downloader")
            } footer: {
                Text("Stow finds, plays and downloads videos with yt-dlp, on this phone. Tap to check that it works.")
            }
            .listRowBackground(colors.raised)

            macSection
                .listRowBackground(colors.raised)

            Section {
                updateRow
                    .id("about")
            } header: {
                Text("About")
            } footer: {
                Text("Stow looks for a new version on GitHub once a day.")
            }
            .listRowBackground(colors.raised)
        }
        .launchScroll(to: "about", with: proxy)
        }
        .tint(colors.accent)
        .scrollContentBackground(.hidden)
        .background(colors.groupedBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: repository.downloadIds().count) { storage = repository.storageUsedBytes() }
        .task { ytDlpVersion = (try? await YtDlp.shared.version())?.ytDlp ?? "unknown" }
        .alert("Unpair this phone?", isPresented: $confirmUnpair) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) {
                shell.closePlayer()
                repository.unpair()
            }
        } message: {
            Text("It stops getting videos until you scan a new code. Downloads stay. Also unpair it on the Mac (Stow › Phone).")
        }
        .alert("Delete watched downloads?", isPresented: $confirmDeleteWatched) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(watchedDownloads) }
        } message: {
            Text(deleteMessage(watchedDownloads))
        }
        .alert("Delete all downloads?", isPresented: $confirmDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete all", role: .destructive) {
                let count = repository.downloadIds().count
                shell.closePlayer()
                repository.deleteAllDownloads()
                storage = repository.storageUsedBytes()
                shell.notify(count == 1 ? "Deleted 1 video" : "Deleted \(count) videos")
            }
        } message: {
            let count = repository.downloadIds().count
            Text("Deletes \(Format.count(count, "video")) (\(storage.map(Format.bytes) ?? "…")) from this phone and stops downloads under way. Videos stay in your lists; they aren't downloaded again unless you ask.")
        }
    }

    @ViewBuilder private var macSection: some View {
        Section {
            if repository.isDemo {
                SettingLabel("Sample videos", "Demo mode: no Mac, nothing is sent anywhere", icon: "desktopcomputer", color: .indigo)
            } else {
                SettingLabel("Paired with your Mac", syncText, icon: "desktopcomputer", color: .indigo)
                Button { confirmUnpair = true } label: {
                    SettingLabel("Unpair this phone", "Firebase project \(repository.prefs.pairedProject ?? "–")",
                                 icon: "iphone.slash", color: .red, destructive: true)
                }
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("New videos come from the Mac each time you open Stow, every minute while it's open, and now and then in the background.")
        }
    }

    /// "Stow 0.1.0 · Up to date", "Update to 0.1.1" (opens the release notes), "Checking…", or
    /// why the check failed. Tapping checks again, or opens the update.
    private var updateRow: some View {
        Button {
            if let update = updates.available, updates.status != .checking {
                shell.update = update
            } else {
                Task { await updates.check() }
            }
        } label: {
            HStack {
                if updates.status == .checking {
                    SettingLabel("Stow \(updates.currentVersion)", "Checking…", icon: "arrow.triangle.2.circlepath", color: .gray)
                    Spacer()
                    ProgressView()
                } else if let update = updates.available {
                    SettingLabel("Update to \(update.version)", "You have \(updates.currentVersion) · see what's new",
                                 icon: "arrow.down.circle.fill", color: colors.accent)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(colors.secondaryText.opacity(0.6))
                } else if case .failed(let message) = updates.status {
                    SettingLabel("Stow \(updates.currentVersion)", "\(message). Tap to try again",
                                 icon: "exclamationmark.triangle.fill", color: .orange)
                } else if let checked = updates.lastChecked {
                    SettingLabel("Stow \(updates.currentVersion)", "Up to date · checked " + Self.lowercasedFirst(Format.ago(checked)),
                                 icon: "checkmark.seal.fill", color: .green)
                } else {
                    SettingLabel("Stow \(updates.currentVersion)", "Tap to look for an update", icon: "arrow.triangle.2.circlepath", color: .gray)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(updates.available == nil ? "Looks for a new version" : "Shows what's new")
    }

    private static func lowercasedFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    /// "Checked 2 minutes ago", or why it couldn't.
    private var syncText: String {
        if let error = repository.syncError { return error }
        guard let last = repository.lastSync else { return "Not checked yet" }
        let ago = Format.ago(last)
        return "Checked " + ago.prefix(1).lowercased() + ago.dropFirst()
    }

    private var watchedDownloads: [VideoItem] {
        repository.downloadItems.filter { $0.watched && $0.state == .downloaded }
    }

    private func deleteMessage(_ items: [VideoItem]) -> String {
        let bytes = items.reduce(Int64(0)) { $0 + ($1.local?.sizeBytes ?? 0) }
        let size = bytes > 0 ? " (\(Format.bytes(bytes)))" : ""
        return "Deletes \(Format.count(items.count, "video"))\(size) from this phone. They stay in your lists."
    }

    private func delete(_ items: [VideoItem]) {
        if items.contains(where: { $0.id == shell.player?.currentId }) { shell.closePlayer() }
        items.forEach { repository.deleteDownload($0.id) }
        storage = repository.storageUsedBytes()
        shell.notify(items.count == 1 ? "Deleted 1 video" : "Deleted \(items.count) videos")
    }
}

/// Download quality, best first. The iPhone stops at 1080p, and says why.
private struct QualityScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(\.stowColors) private var colors

    var body: some View {
        let prefs = repository.prefs
        List {
            Section {
                ForEach(DownloadQuality.available, id: \.self) { quality in
                    Button {
                        prefs.downloadQuality = quality
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quality == .p1080 ? "1080p (default)" : quality.label)
                                    .foregroundStyle(colors.text)
                                Text(quality.detail)
                                    .font(.footnote)
                                    .foregroundStyle(colors.secondaryText)
                            }
                            Spacer()
                            if prefs.downloadQuality == quality {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(colors.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(prefs.downloadQuality == quality ? .isSelected : [])
                }
            } footer: {
                Text("The highest a download takes. Videos without it download at the next best. Videos already downloaded stay as they are.\n\nOn iPhone, downloads stop at 1080p: the phone saves YouTube's H.264 video as it is, and YouTube has none above 1080p.")
            }
            .listRowBackground(colors.raised)
        }
        .scrollContentBackground(.hidden)
        .background(colors.groupedBackground)
        .navigationTitle("Download quality")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A setting: a white symbol on a colored rounded square, the title and a line under it.
private struct SettingLabel: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var destructive = false
    @Environment(\.stowColors) private var colors
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, _ subtitle: String, icon: String, color: Color, destructive: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.destructive = destructive
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(destructive ? colors.destructive : colors.text)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(colors.secondaryText)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .padding(.vertical, 2)
    }
}

/// The four themes as little phone screens in their colors; tap one to switch.
private struct ThemePicker: View {
    let selected: AppTheme
    let onSelect: (AppTheme) -> Void
    @Environment(\.stowColors) private var colors

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTheme.allCases, id: \.self) { theme in
                let isSelected = theme == selected
                Button { onSelect(theme) } label: {
                    VStack(spacing: 8) {
                        Group {
                            if theme == .system {
                                HStack(spacing: 0) {
                                    MiniScreen(colors: .light)
                                    MiniScreen(colors: .dark)
                                }
                            } else {
                                MiniScreen(colors: StowColors.of(theme, systemDark: false))
                            }
                        }
                        .frame(width: isSelected ? 54 : 60, height: isSelected ? 84 : 90)
                        .clipShape(RoundedRectangle(cornerRadius: isSelected ? 8 : 11, style: .continuous))
                        .frame(width: 62, height: 92)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isSelected ? colors.accent : colors.divider, lineWidth: isSelected ? 2.5 : 1)
                        }
                        Text(theme.label)
                            .font(.footnote.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? colors.accent : colors.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// A tiny screen in a theme's colors: a title, a thumbnail, a line of text and an accent dot.
private struct MiniScreen: View {
    let colors: StowColors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(colors.text).frame(maxWidth: 28).frame(height: 5)
            RoundedRectangle(cornerRadius: 4).fill(colors.chip).frame(maxWidth: 44).frame(height: 24).padding(.top, 7)
            RoundedRectangle(cornerRadius: 2).fill(colors.secondaryText).frame(maxWidth: 36).frame(height: 4).padding(.top, 5)
            Spacer(minLength: 0)
            Capsule().fill(colors.raised).frame(maxWidth: 44).frame(height: 10)
                .overlay(alignment: .leading) { Circle().fill(colors.accent).frame(width: 6, height: 6).padding(.leading, 6) }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.background)
    }
}
