import SwiftUI

/// One Inbox video in the menu bar panel. Click opens it; hovering reveals a dismiss button.
struct InboxRow: View {
    let item: InboxItem
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                VideoThumbnail(url: item.video.thumbnailURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.video.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if item.video.isMembersOnly {
                        MembersBadge()
                    }
                }
                .padding(.trailing, 14)
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .padding(10)
            }
        }
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
        .help(item.video.title)
    }

    private var subtitle: String {
        let date = item.video.publishedAt ?? item.foundAt
        return "\(item.video.channelTitle) · \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
    }
}

private struct VideoThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct MembersBadge: View {
    var body: some View {
        Label("Members only", systemImage: "star.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.green.opacity(0.15), in: Capsule())
    }
}

#if DEBUG
#Preview {
    InboxRow(item: .preview, onOpen: {}, onDismiss: {})
        .frame(width: 340)
        .padding(.vertical)
}
#endif
