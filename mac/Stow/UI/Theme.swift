import AppKit
import SwiftUI

/// How the app looks (View › Theme). Paper is a light theme in warm off-white with a terracotta
/// accent; the phone has the same four.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark, paper

    static let storageKey = "theme"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        case .paper: "Paper"
        }
    }

    /// Highlights (badges, selected days): Paper's terracotta, else the system accent.
    var accent: Color { self == .paper ? Paper.accent : .accentColor }

    /// The window appearance; nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light, .paper: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Paper's colors (the same as the phone's).
enum Paper {
    static let background = Color(nsColor: nsBackground)
    static let nsBackground = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255, alpha: 1)
    /// The sidebar, a step darker than the content.
    static let sidebar = Color(.sRGB, red: 0xF0 / 255, green: 0xEE / 255, blue: 0xE6 / 255)
    static let accent = Color(.sRGB, red: 0xC9 / 255, green: 0x64 / 255, blue: 0x42 / 255)
}

extension EnvironmentValues {
    @Entry var appTheme: AppTheme = .system
}

extension View {
    /// Under Paper, the area (and the lists, tables and forms in it) shows `color` instead of
    /// the system background; other themes keep the system look.
    func themedBackground(_ color: Color = Paper.background) -> some View {
        modifier(ThemedBackground(color: color))
    }
}

private struct ThemedBackground: ViewModifier {
    @Environment(\.appTheme) private var theme
    let color: Color

    func body(content: Content) -> some View {
        let paper = theme == .paper
        content
            .scrollContentBackground(paper ? .hidden : .automatic)
            .background(paper ? color : .clear)
    }
}
