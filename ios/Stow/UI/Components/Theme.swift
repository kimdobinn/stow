import StowKit
import SwiftUI
import UIKit

/// Stow's colors by role, the same as the Android app's (ui/Theme.kt).
nonisolated struct StowColors: Equatable, Sendable {
    /// Screens with content: plain lists and feeds.
    var background: Color
    /// Behind inset grouped sections (settings, sheets).
    var groupedBackground: Color
    var text: Color
    var secondaryText: Color
    /// Fills for controls: chips, buttons.
    var chip: Color
    var chipSelected: Color
    var chipSelectedText: Color
    var divider: Color
    /// Grouped rows and cards on `groupedBackground`.
    var raised: Color
    /// Primary actions, the selected tab, status.
    var accent: Color
    var destructive: Color

    static let light = StowColors(
        background: Color(hex: 0xFFFFFF), groupedBackground: Color(hex: 0xF2F2F7),
        text: Color(hex: 0x000000), secondaryText: Color(hex: 0x6C6C70),
        chip: Color(hex: 0xEEEEF0), chipSelected: Color(hex: 0x000000), chipSelectedText: .white,
        divider: Color(hex: 0xD1D1D6), raised: Color(hex: 0xFFFFFF), accent: Color(hex: 0xFF2D55),
        destructive: Color(hex: 0xFF3B30)
    )

    static let dark = StowColors(
        background: Color(hex: 0x000000), groupedBackground: Color(hex: 0x000000),
        text: Color(hex: 0xFFFFFF), secondaryText: Color(hex: 0x98989F),
        chip: Color(hex: 0x2C2C2E), chipSelected: Color(hex: 0xFFFFFF), chipSelectedText: Color(hex: 0x000000),
        divider: Color(hex: 0x38383A), raised: Color(hex: 0x1C1C1E), accent: Color(hex: 0xFF375F),
        destructive: Color(hex: 0xFF453A)
    )

    /// Warm paper: off-white and cream with a terracotta accent.
    static let paper = StowColors(
        background: Color(hex: 0xFAF9F5), groupedBackground: Color(hex: 0xF0EEE6),
        text: Color(hex: 0x1F1E1D), secondaryText: Color(hex: 0x66655F),
        chip: Color(hex: 0xEDEBE3), chipSelected: Color(hex: 0x1F1E1D), chipSelectedText: Color(hex: 0xFAF9F5),
        divider: Color(hex: 0xDEDBD0), raised: Color(hex: 0xFFFEFB), accent: Color(hex: 0xC96442),
        destructive: Color(hex: 0xD70015)
    )

    /// The colors a theme uses (Automatic follows the phone's dark mode).
    static func of(_ theme: AppTheme, systemDark: Bool) -> StowColors {
        if theme.isDark(systemDark: systemDark) { return .dark }
        return theme == .paper ? .paper : .light
    }
}

/// The app icon's orange, pink and purple: the download ring and the app mark, nowhere else.
nonisolated enum StowGradient {
    static let colors: [Color] = [Color(hex: 0xFF8A3D), Color(hex: 0xFF2D55), Color(hex: 0x8B5CF6)]
    static let linear = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Closed, for rings.
    static let angular = AngularGradient(colors: colors + [colors[0]], center: .center)
}

extension Color {
    nonisolated init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

nonisolated private struct StowColorsKey: EnvironmentKey {
    static let defaultValue = StowColors.light
}

nonisolated private struct CalmKey: EnvironmentKey {
    static let defaultValue = false
}

nonisolated private struct ChannelAvatarsKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    /// The theme's colors (set by `stowTheme`).
    nonisolated var stowColors: StowColors {
        get { self[StowColorsKey.self] }
        set { self[StowColorsKey.self] = newValue }
    }

    /// Calm mode: titles only, no thumbnails.
    nonisolated var calm: Bool {
        get { self[CalmKey.self] }
        set { self[CalmKey.self] = newValue }
    }

    /// Channel pictures by channel id (the Mac's channels', YouTube's feeds' and channel pages').
    nonisolated var channelAvatars: [String: String] {
        get { self[ChannelAvatarsKey.self] }
        set { self[ChannelAvatarsKey.self] = newValue }
    }
}

/// Applies the settings that change the whole app: the theme's colors, calm mode and black and
/// white. Sheets and full-screen covers don't inherit modifiers, so their content uses it too.
struct StowThemeModifier: ViewModifier {
    let prefs: Prefs
    var avatars: [String: String]?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.channelAvatars) private var inheritedAvatars

    func body(content: Content) -> some View {
        let colors = StowColors.of(prefs.theme, systemDark: scheme == .dark)
        content
            .environment(\.stowColors, colors)
            .environment(\.calm, prefs.calm)
            .environment(\.channelAvatars, avatars ?? inheritedAvatars)
            .tint(colors.accent)
            .grayscale(prefs.grayscale ? 1 : 0)
    }
}

extension View {
    func stowTheme(_ prefs: Prefs, avatars: [String: String]? = nil) -> some View {
        modifier(StowThemeModifier(prefs: prefs, avatars: avatars))
    }
}

/// Light, dark or the phone's choice for every window (so sheets, alerts and menus follow too).
/// SwiftUI's preferredColorScheme doesn't reliably go back to the phone's setting once set.
enum WindowStyle {
    static func apply(_ theme: AppTheme, crossfade: Bool = false) {
        if crossfade { self.crossfade() }
        let style: UIUserInterfaceStyle = switch theme {
        case .system: .unspecified
        case .light, .paper: .light
        case .dark: .dark
        }
        // UIKit's own controls (alert buttons, menus, the tab bar) take the window's tint.
        let tint = UIColor { traits in
            UIColor(StowColors.of(theme, systemDark: traits.userInterfaceStyle == .dark).accent)
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                if window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
                window.tintColor = tint
            }
        }
    }

    /// Fades from how the app looks now to how it looks after this change, in one go: SwiftUI's
    /// colors and UIKit's bars and lists would otherwise switch on their own, one animated and
    /// one not. Call it before the change reaches the screen (from onChange).
    static func crossfade(duration: TimeInterval = 0.25) {
        for scene in UIApplication.shared.connectedScenes {
            guard let window = (scene as? UIWindowScene)?.keyWindow,
                  let snapshot = window.snapshotView(afterScreenUpdates: false) else { continue }
            snapshot.isUserInteractionEnabled = false
            window.addSubview(snapshot)
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }
    }
}
