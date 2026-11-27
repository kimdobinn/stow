import os
import UIKit

/// The app stays portrait, except on the watch page: there, turning the phone (or the full screen
/// button) shows the video full screen.
enum Orientation {
    /// What AppDelegate tells iOS the app may turn to.
    static private(set) var allowed: UIInterfaceOrientationMask = .portrait

    /// The watch page opened or closed.
    static func allowLandscape(_ allow: Bool) {
        let mask: UIInterfaceOrientationMask = allow ? .allButUpsideDown : .portrait
        guard mask != allowed else { return }
        allowed = mask
        for scene in windowScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !allow { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { @Sendable _ in } }
        }
    }

    /// The full screen button: sideways, or back upright.
    static func setFullScreen(_ on: Bool) {
        Logger(subsystem: "dev.stow.ios", category: "player").info("Full screen \(on ? "on" : "off", privacy: .public)")
        for scene in windowScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            let current = scene.interfaceOrientation
            let target: UIInterfaceOrientationMask = on ? (current == .landscapeLeft ? .landscapeLeft : .landscapeRight) : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { @Sendable error in
                Logger(subsystem: "dev.stow.ios", category: "player").warning("Rotation refused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static var windowScenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }
}
