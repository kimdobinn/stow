import SwiftUI

// Small building blocks shared by the Alarm sections.

/// A form row: the title on the left, `content` on the right, both vertically centered
/// (LabeledContent top-aligns its label next to taller custom controls).
struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            content
        }
    }
}

/// A value label followed by its stepper, aligned on the trailing edge of a form row.
struct StepperValue<Control: View>: View {
    let text: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 8) {
            Text(text).monospacedDigit()
            control.labelsHidden()
        }
    }
}

/// A button that shows a spinner while its action runs.
struct TestButton: View {
    let title: String
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .opacity(isRunning ? 0 : 1)
                .overlay {
                    if isRunning { ProgressView().controlSize(.small) }
                }
        }
        .fixedSize()
        .disabled(isRunning)
    }
}

/// A symbol in a tinted rounded square, like System Settings' row icons but larger.
struct AlarmIcon: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24))
    }
}

/// Always red, even while the window is in the background behind the fullscreen player
/// (where `.borderedProminent` turns gray).
struct StopButtonStyle: ButtonStyle {
    var font: Font = .body.weight(.semibold)
    var padding = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white)
            .padding(padding)
            .background(Color.red.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}
