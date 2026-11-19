import SwiftUI

/// Holds a control's in-progress value and saves it when the user lets go or pauses, because
/// every alarm settings change rewrites settings.json. `content` gets the draft binding and an
/// `onEditingChanged` handler for controls that report it (sliders, steppers).
struct Committed<Value: Equatable, Content: View>: View {
    let value: Value
    let commit: (Value) -> Void
    let content: (Binding<Value>, @escaping (Bool) -> Void) -> Content

    @State private var draft: Value?
    @State private var isEditing = false
    @State private var pendingCommit: Task<Void, Never>?

    init(_ value: Value, commit: @escaping (Value) -> Void,
         @ViewBuilder content: @escaping (Binding<Value>, @escaping (Bool) -> Void) -> Content) {
        self.value = value
        self.commit = commit
        self.content = content
    }

    var body: some View {
        content(Binding(get: { draft ?? value }, set: { draft = $0; scheduleCommit() }), editingChanged)
            .onDisappear(perform: flush)
    }

    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        if !editing { flush() }
    }

    /// Covers keyboard edits and controls that never report the end of editing.
    private func scheduleCommit() {
        pendingCommit?.cancel()
        pendingCommit = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !isEditing else { return }
            flush()
        }
    }

    private func flush() {
        pendingCommit?.cancel()
        pendingCommit = nil
        if let draft, draft != value { commit(draft) }
        draft = nil
    }
}
