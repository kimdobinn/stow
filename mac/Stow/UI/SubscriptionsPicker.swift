import SwiftUI

/// Sheet listing the user's subscriptions as checkboxes; nothing is pre-selected.
/// Channels that are already added are shown checked and disabled.
struct SubscriptionsPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var phase = Phase.loading
    @State private var picked = Set<ChannelInfo.ID>()
    @State private var query = ""
    @State private var isAdding = false

    private enum Phase {
        case loading
        case loaded([ChannelInfo])
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480, height: 520)
        .task { await load() }
    }

    private var addedIds: Set<String> { Set(model.channels.map(\.id)) }

    private var subscriptions: [ChannelInfo] {
        if case .loaded(let list) = phase { list } else { [] }
    }

    private var filtered: [ChannelInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return subscriptions }
        return subscriptions.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.handle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose from Subscriptions").font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading subscriptions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Subscriptions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        case .loaded:
            List(filtered) { info in
                row(info)
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private func row(_ info: ChannelInfo) -> some View {
        let added = addedIds.contains(info.id)
        return Toggle(isOn: Binding(
            get: { added || picked.contains(info.id) },
            set: { on in
                if on { picked.insert(info.id) } else { picked.remove(info.id) }
            }
        )) {
            HStack(spacing: 10) {
                ChannelAvatar(url: info.avatarURL, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.title).lineLimit(1)
                    if let handle = info.handle {
                        Text(handle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if added {
                    Text("Added").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(added)
    }

    private var footer: some View {
        HStack {
            Button("Select All") {
                picked.formUnion(filtered.map(\.id).filter { !addedIds.contains($0) })
            }
            .disabled(subscriptions.isEmpty || isAdding)
            Button("Select None") { picked.removeAll() }
                .disabled(picked.isEmpty || isAdding)
            Spacer()
            if isAdding {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(picked.count == 1 ? "Add 1 channel" : "Add \(picked.count) channels", action: add)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || isAdding)
        }
        .padding(16)
    }

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await model.loadSubscriptions())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func add() {
        // Keep YouTube's order rather than the Set's.
        let chosen = subscriptions.filter { picked.contains($0.id) && !addedIds.contains($0.id) }
        isAdding = true
        Task {
            await model.addSubscriptions(chosen)
            isAdding = false
            dismiss()
        }
    }
}

#if DEBUG
#Preview {
    SubscriptionsPicker().environment(AppModel.preview)
}
#endif
