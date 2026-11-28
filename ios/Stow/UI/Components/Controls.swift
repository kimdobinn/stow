import StowKit
import SwiftUI

/// Stow's mark: a play button on the icon's gradient.
struct StowMark: View {
    var size: CGFloat = 88

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(StowGradient.linear)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.03)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A filter token: a capsule, filled with the text color when selected (no accent, so content leads).
struct Chip: View {
    let label: String
    let selected: Bool
    var systemImage: String?
    let action: () -> Void
    @Environment(\.stowColors) private var colors

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.subheadline.weight(.semibold))
                }
                if !label.isEmpty {
                    Text(label).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(selected ? colors.chipSelectedText : colors.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(selected ? colors.chipSelected : colors.chip, in: Capsule())
            // The colors cross-fade when picked, even when what the chip shows below changes at
            // once (withoutAnimation).
            .transaction(value: selected) { transaction in
                transaction.animation = Motion.quick
                transaction.disablesAnimations = false
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Chips in a row that scrolls sideways.
struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }
}

/// A capsule button; `filled` is the screen's one primary action, in the accent.
struct PillButton: View {
    let label: String
    var systemImage: String?
    var filled = false
    let action: () -> Void
    @Environment(\.stowColors) private var colors

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(label).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? .white : colors.text)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(filled ? colors.accent : colors.chip, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// A button that gives a little under the finger, like YouTube's pills and chips: slightly
/// smaller and dimmer while pressed, springing back when let go.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct SectionHeader<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.stowColors) private var colors

    var body: some View {
        // With large text, what's on the right goes under the title instead of squeezing it.
        ViewThatFits(in: .horizontal) {
            HStack {
                title.fixedSize()
                Spacer()
                trailing
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: some View {
        Text(text).font(.title3.weight(.bold)).foregroundStyle(colors.text)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

/// A quiet line of text where a list has nothing to show.
struct EmptyState: View {
    let text: String
    @Environment(\.stowColors) private var colors

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(colors.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(32)
    }
}

/// Footnote text under a list or section.
struct FootnoteText: View {
    let text: String
    @Environment(\.stowColors) private var colors

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(colors.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A short message at the bottom of the screen, like YouTube's snackbars.
struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(hex: 0x323232), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Asks for a name (new group, rename): an alert with a text field.
struct NameAlert: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    var initial = ""
    var confirm = "Save"
    let onSave: (String) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.sentences)
                Button("Cancel", role: .cancel) {}
                Button(confirm) {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onSave(trimmed) }
                }
            }
            .onChange(of: isPresented) { _, shown in
                if shown { name = initial }
            }
    }
}

extension View {
    func nameAlert(_ title: String, isPresented: Binding<Bool>, initial: String = "", confirm: String = "Save",
                   onSave: @escaping (String) -> Void) -> some View {
        modifier(NameAlert(title: title, isPresented: isPresented, initial: initial, confirm: confirm, onSave: onSave))
    }
}
