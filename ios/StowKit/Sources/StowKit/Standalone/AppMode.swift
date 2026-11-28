import Foundation

/// How the app is used: with the Mac (paired by QR code), on its own, or not chosen yet.
public enum AppMode: String, Sendable, Equatable {
    /// First launch: the Welcome screen asks.
    case choosing
    case mac
    case standalone

    /// The stored value of `appMode` ("mac" or "standalone").
    public var stored: String? {
        switch self {
        case .choosing: nil
        case .mac: "mac"
        case .standalone: "standalone"
        }
    }

    /// Worked out once at launch, from the preferences only (never Firebase). An install paired
    /// before modes existed resolves to `.mac`, and `write` says to store it.
    public static func resolve(stored: String?, hasPairing: Bool) -> (mode: AppMode, write: String?) {
        switch stored {
        case "mac": return (.mac, nil)
        case "standalone": return (.standalone, nil)
        default: return hasPairing ? (.mac, "mac") : (.choosing, nil)
        }
    }
}
