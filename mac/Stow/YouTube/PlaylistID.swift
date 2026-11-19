import Foundation

/// Uploads-playlist ids derived from a "UC..." channel id.
enum PlaylistID {
    /// Public long-form uploads (no Shorts, no lives).
    static func longForm(channelId: String) -> String {
        "UULF" + channelId.dropFirst(2)
    }

    /// Members-only long-form uploads. UUMF rather than UUMO because UUMO also lists
    /// members-only Shorts, which Stow ignores.
    static func membersOnly(channelId: String) -> String {
        "UUMF" + channelId.dropFirst(2)
    }
}
