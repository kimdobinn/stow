import SwiftUI

/// A channel's avatar in a circle, with a placeholder while loading or when missing.
struct ChannelAvatar: View {
    let url: URL?
    var size: CGFloat = 32

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
