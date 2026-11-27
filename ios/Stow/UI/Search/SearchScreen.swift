import StowKit
import SwiftUI

/// Search, as in the YouTube app: as you type it suggests your recent searches and matching videos
/// you already have; Search on the keyboard looks through all of YouTube (with yt-dlp, on the phone).
struct SearchScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @State private var text = ""
    @State private var searchFocused = false
    @State private var search = SearchModel()

    var body: some View {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        List {
            if let submitted = search.submitted, query == submitted {
                results(for: submitted)
            } else if query.isEmpty {
                recents
            } else {
                suggestions(for: query)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, isPresented: $searchFocused, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search YouTube")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) { run(text) }
        .task {
            if let query = LaunchRoutes.takeSearch() {
                run(query)
                return
            }
            // Straight to typing, as on YouTube (once the push has finished).
            guard search.submitted == nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            searchFocused = true
        }
    }

    private func run(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !q.isEmpty else { return }
        self.text = q
        hideKeyboard()
        search.run(q, repository: repository)
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - Results

    @ViewBuilder private func results(for submitted: String) -> some View {
        if search.loading {
            LoadingRow().plainListRow()
        } else if let error = search.error {
            LoadErrorView(title: "Couldn't search YouTube.", message: error) { run(submitted) }
                .plainListRow()
        } else {
            let results = search.resultIds.compactMap(repository.item)
            if results.isEmpty {
                EmptyState("No videos found for “\(submitted)”.").plainListRow()
            } else {
                let actions = shell.actions.playing { shell.play(results, start: $0) }
                ForEach(results) { VideoCard(item: $0, actions: actions).plainListRow() }
                EmptyState("Shorts and live streams are left out.").plainListRow()
            }
        }
    }

    // MARK: - Before searching

    @ViewBuilder private var recents: some View {
        let recent = repository.prefs.recentSearches
        if recent.isEmpty {
            EmptyState("Search all of YouTube. Shorts and live streams are left out.").plainListRow()
        } else {
            HStack {
                Text("Recent searches")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(colors.secondaryText)
                Spacer()
                Button("Clear") { withAnimation { repository.prefs.clearRecentSearches() } }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .plainListRow()
            ForEach(recent, id: \.self) { recentRow($0) }
        }
    }

    @ViewBuilder private func suggestions(for query: String) -> some View {
        SuggestionRow(text: query, history: false) { run(query) }
        ForEach(SearchSuggestions.pastSearches(repository.prefs.recentSearches, matching: query), id: \.self) { recentRow($0) }
        let yours = SearchSuggestions.yourVideos(repository.everything, matching: query)
        if !yours.isEmpty {
            Text("Your videos")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(colors.secondaryText)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .plainListRow()
            ForEach(yours) { VideoRow(item: $0, actions: shell.actions).plainListRow() }
        }
    }

    private func recentRow(_ recent: String) -> some View {
        SuggestionRow(text: recent, history: true, onRemove: {
            withAnimation { repository.prefs.removeRecentSearch(recent) }
        }) { run(recent) }
            .swipeActions {
                Button("Remove", systemImage: "trash", role: .destructive) { repository.prefs.removeRecentSearch(recent) }
            }
    }
}

/// What to suggest while typing: every word typed must appear (in any order, any case).
enum SearchSuggestions {
    /// Up to five earlier searches, not the one typed exactly.
    static func pastSearches(_ recent: [String], matching query: String) -> [String] {
        let words = words(query)
        return Array(recent.filter { r in
            r.caseInsensitiveCompare(query) != .orderedSame && words.allSatisfy { r.lowercased().contains($0) }
        }.prefix(5))
    }

    /// Videos you already have (by title or channel).
    static func yourVideos(_ items: [VideoItem], matching query: String) -> [VideoItem] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        return items.filter { item in
            let haystack = (item.video.title + " " + item.video.channelTitle).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// One YouTube search at a time: a new one (or Try again) cancels the one under way.
@MainActor
@Observable
final class SearchModel {
    private(set) var submitted: String?
    private(set) var resultIds: [String] = []
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func run(_ query: String, repository: Repository) {
        task?.cancel()
        submitted = query
        resultIds = []
        error = nil
        loading = true
        task = Task { [weak self] in
            do {
                let ids = try await repository.searchYouTube(query)
                guard !Task.isCancelled else { return }
                self?.resultIds = ids
            } catch {
                // A newer search replaced this one: it's still loading.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.error = ErrorText.short(error)
            }
            self?.loading = false
        }
    }
}

/// A search suggestion: a past search (a clock, removable) or "search for what you typed".
private struct SuggestionRow: View {
    let text: String
    let history: Bool
    var onRemove: (() -> Void)?
    let action: () -> Void
    @Environment(\.stowColors) private var colors

    var body: some View {
        HStack(spacing: 16) {
            Button(action: action) {
                HStack(spacing: 16) {
                    Image(systemName: history ? "clock.arrow.circlepath" : "magnifyingglass")
                        .font(.body)
                        .foregroundStyle(colors.secondaryText)
                        .frame(width: 24)
                    Text(text)
                        .font(.body)
                        .foregroundStyle(colors.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(history ? text : "Search for \(text)")
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(colors.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove “\(text)”")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .plainListRow()
    }
}
