import StowKit
import SwiftUI

/// Standalone: follow a channel by what you paste or type: a channel URL, an @handle, a channel
/// ID, or a video's URL (its channel).
struct AddChannelSheet: View {
    @Environment(Repository.self) private var repository
    @Environment(Shell.self) private var shell
    @Environment(\.stowColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var adding = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Channel URL, @handle or channel ID", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit(add)
                        .disabled(adding)
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(colors.destructive)
                    } else {
                        Text("For example @NASA, youtube.com/@NASA, or a link to one of its videos.")
                    }
                }
                .listRowBackground(colors.raised)
            }
            .scrollContentBackground(.hidden)
            .background(colors.groupedBackground)
            .navigationTitle("Add a channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if adding {
                        ProgressView()
                    } else {
                        Button("Add", action: add).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func add() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding, let standalone = repository.standalone else { return }
        adding = true
        failure = nil
        Task {
            defer { adding = false }
            do {
                let channel = try await standalone.addChannel(input: text)
                dismiss()
                shell.notify("Following \(channel.title)")
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "Couldn't add that channel."
            }
        }
    }
}
