import SwiftUI

/// New videos as a grid of large cards. Click opens a video; hover reveals a dismiss button.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirmsClear = false

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 20, alignment: .top)]

    var body: some View {
        content
            .toolbar {
                ToolbarItem {
                    Button("Clear All", systemImage: "checkmark.circle") { confirmsClear = true }
                        .help("Dismiss every video in the Inbox")
                        .disabled(model.inbox.isEmpty)
                }
            }
            .confirmationDialog("Clear \(model.inbox.count) videos from the Inbox?", isPresented: $confirmsClear) {
                Button("Clear All", role: .destructive) { model.dismissAllInbox() }
            } message: {
                Text("This can't be undone.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.channels.isEmpty {
            ContentUnavailableView("No Channels Yet", systemImage: "person.2",
                                   description: Text("Add channels in the Channels section."))
        } else if model.inbox.isEmpty {
            ContentUnavailableView("No New Videos", systemImage: "tray",
                                   description: Text("New uploads from your channels show up here."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(model.inbox) { item in
                        VideoCard(item: item) {
                            openURL(item.video.watchURL)
                        } onDismiss: {
                            model.dismissInbox(videoId: item.id)
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct VideoCard: View {
    let item: InboxItem
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.video.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.video.title)
        .contextMenu {
            Button("Open on YouTube", action: onOpen)
            Button("Dismiss", action: onDismiss)
        }
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: item.video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                if item.video.isMembersOnly {
                    MembersBadge().padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .padding(8)
                }
            }
            .shadow(color: .black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 8 : 3, y: 2)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private var subtitle: String {
        let date = item.video.publishedAt ?? item.foundAt
        return "\(item.video.channelTitle) · \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct MembersBadge: View {
    var body: some View {
        Label("Members only", systemImage: "star.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green, in: Capsule())
    }
}

#if DEBUG
#Preview {
    InboxView()
        .environment(AppModel.preview)
        .frame(width: 900, height: 600)
}
#endif
