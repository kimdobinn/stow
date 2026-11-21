import SwiftUI

/// Settings › Scrolling: how fast the mouse wheel and trackpad scroll Stow, and wheel gliding.
struct ScrollingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Scrolling") {
            LabeledContent {
                HStack(spacing: 10) {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: speed, in: ScrollSettings.speedRange, step: 0.5)
                        .frame(minWidth: 180)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                    Text(model.scrolling.speed.formatted(.number.precision(.fractionLength(0...1))) + "×")
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            } label: {
                Text("Speed")
                Text("1× is macOS's own speed.")
            }
            Toggle(isOn: Binding(
                get: { model.scrolling.smooth },
                set: { model.setScrolling(ScrollSettings(speed: model.scrolling.speed, smooth: $0)) }
            )) {
                Text("Smooth mouse wheel")
                Text("Each notch glides instead of jumping. Trackpads already scroll smoothly.")
            }
            if model.scrolling != .default {
                Button("Restore Defaults") { model.setScrolling(.default) }
            }
        }
    }

    private var speed: Binding<Double> {
        Binding(
            get: { model.scrolling.speed },
            set: { model.setScrolling(ScrollSettings(speed: $0, smooth: model.scrolling.smooth)) }
        )
    }
}
