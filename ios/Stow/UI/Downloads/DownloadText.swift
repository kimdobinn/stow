import StowKit

/// What a download waiting its turn says, honest about what it waits for.
enum DownloadText {
    static func waiting(_ item: VideoItem, hold: DownloadManager.Hold) -> String {
        switch hold {
        case .noConnection: return "Waiting for a connection"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .suspended: return "Paused · open Stow to continue"
        case .none: return item.local?.error != nil ? "Retrying soon" : "Waiting to download"
        }
    }

    /// The line over the Downloads list while downloads wait for something other than their turn.
    static func banner(_ hold: DownloadManager.Hold, waiting: Int) -> String? {
        guard waiting > 0 else { return nil }
        switch hold {
        case .none: return nil
        case .noConnection: return "No connection. Downloads continue when you're back online."
        case .waitingForWiFi: return "Downloads wait for Wi-Fi. You can allow mobile data in Settings."
        case .suspended: return "Paused while Stow was in the background."
        }
    }

    /// Under the list: iOS only lets Stow download for a short while after you leave it.
    static let backgroundNote = "Downloads run while Stow is open, and for a few minutes after you leave it. iOS may give Stow more time later, often overnight while charging."
}
