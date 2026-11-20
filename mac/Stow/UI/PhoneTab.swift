import SwiftUI
import UniformTypeIdentifiers

/// Firebase connection, paired phones (pair by QR code) and what was sent to them.
struct PhoneTab: View {
    @Environment(AppModel.self) private var model
    @State private var importsKey = false
    @State private var importError: String?
    @State private var showsPairing = false
    @State private var removing: PhoneMember?

    private var phone: PhoneSync { model.phone }

    var body: some View {
        Form {
            Section("Firebase") {
                LabeledContent {
                    HStack(spacing: 8) {
                        if phone.connection == .connecting {
                            ProgressView().controlSize(.small)
                        }
                        Button(phone.connection == .notSetUp ? "Choose Key File…" : "Change Key…") { importsKey = true }
                    }
                } label: {
                    ConnectionStatus()
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let importError {
                    Text(importError).font(.callout).foregroundStyle(.red)
                }
            }
            Section("Phones") {
                if phone.members.isEmpty {
                    Text("No phone paired yet. Open Stow on the phone and scan the pairing QR code.")
                        .foregroundStyle(.secondary)
                }
                ForEach(phone.members) { member in
                    LabeledContent {
                        Button("Unpair…") { removing = member }
                    } label: {
                        Label {
                            Text(member.name)
                            if let date = member.pairedAt {
                                Text("Paired \(date.formatted(date: .abbreviated, time: .omitted))")
                            }
                        } icon: {
                            Image(systemName: "iphone")
                        }
                    }
                }
                Button("Pair a Phone…") { showsPairing = true }
                    .disabled(phone.connection != .connected)
            }
            if phone.isPaired {
                Section {
                    SentList()
                } header: {
                    HStack {
                        Text("Sent to Phone")
                        Spacer()
                        SyncStatus()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importsKey, allowedContentTypes: [.json]) { result in
            importError = nil
            guard case .success(let url) = result else { return }
            Task {
                do {
                    try await phone.importKey(from: url)
                } catch {
                    importError = error.logDescription
                }
            }
        }
        .sheet(isPresented: $showsPairing, onDismiss: { phone.cancelPairing() }) {
            PairingSheet()
        }
        .confirmationDialog("Unpair \(removing?.name ?? "this phone")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Unpair", role: .destructive) {
                if let removing { Task { await phone.removeMember(id: removing.id) } }
            }
        } message: {
            Text("It stops receiving videos and loses access to the sync data. Videos already on it stay.")
        }
    }

    private var explanation: String {
        switch phone.connection {
        case .notSetUp:
            "Stow talks to the phone through your own free Firebase project. Do the one-time setup in alt-tube/firebase/SETUP.md, then choose the key file it downloads."
        default:
            "New videos of channels with Phone on are sent to the phone, which downloads them right away. Watched status, channels and the YouTube sign-in (encrypted) sync too."
        }
    }
}

private struct ConnectionStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.phone.connection {
            case .notSetUp:
                Text("Not set up")
            case .connecting:
                Text("Connecting…")
            case .connected:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected to \(model.phone.projectId ?? "Firebase")")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(3).help(message)
            }
        }
    }
}

/// "Synced 1 min ago", "Syncing…" or the last error.
private struct SyncStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.everyMinute) { _ in
            Group {
                if model.phone.isSyncing {
                    Text("Syncing…")
                } else if let error = model.phone.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").lineLimit(1).help(error)
                } else if let date = model.phoneState.lastSync {
                    Text("Synced \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        }
    }
}

/// The 20 videos sent most recently, with what the phone did with them.
private struct SentList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.phoneState.pending.map(\.id)
        let sent = model.phoneState.sent.sorted { $0.value.sentAt > $1.value.sentAt }.map(\.key)
        let ids = Array((pending + sent.filter { !pending.contains($0) }).prefix(20))
        if ids.isEmpty {
            Text("Nothing sent yet. New videos of channels with Phone on go automatically; right-click any video in the Inbox to send it.")
                .foregroundStyle(.secondary)
        }
        ForEach(ids, id: \.self) { id in
            LabeledContent {
                Text(state(id)).foregroundStyle(model.phoneState.sent[id]?.download?.state == .failed ? .red : .secondary)
            } label: {
                Text(model.phoneVideo(id: id)?.title ?? id).lineLimit(1)
                if let video = model.phoneVideo(id: id) { Text(video.channelTitle) }
            }
        }
    }

    private func state(_ id: String) -> String {
        guard let entry = model.phoneState.sent[id] else { return "Sending…" }
        switch entry.download?.state {
        case nil: return "Sent \(entry.sentAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .downloaded: return "On phone"
        case .failed: return "Failed\(entry.download?.error.map { ": \($0)" } ?? "")"
        case .deleted: return "Deleted on phone"
        }
    }
}

/// The QR code the phone scans, until it pairs or 10 minutes pass.
private struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair a Phone").font(.title2.weight(.bold))
            content
            HStack {
                Spacer()
                Button(isPaired ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(isPaired ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { model.phone.startPairing() }
    }

    private var isPaired: Bool {
        if case .paired = model.phone.pairing?.status { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.phone.pairing?.status {
        case .waiting:
            if let image = model.phone.pairing?.invite.qrImage(size: 260) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .frame(width: 260, height: 260)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Open Stow on the phone and scan this code. It works once and expires in 10 minutes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
        case .paired(let name):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("Paired with \(name)").font(.headline)
        case .expired:
            Text("The code expired.").foregroundStyle(.secondary)
            Button("New Code") { model.phone.startPairing() }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case nil:
            ProgressView()
        }
    }
}

#if DEBUG
#Preview {
    PhoneTab()
        .environment(AppModel.preview)
        .frame(width: 700, height: 600)
}
#endif
