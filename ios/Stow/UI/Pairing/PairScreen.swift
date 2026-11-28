import StowKit
import SwiftUI

/// Scan the QR code from Stow › Phone › Pair a Phone on the Mac (or paste its stow://pair link).
struct PairScreen: View {
    @Environment(Repository.self) private var repository
    @Environment(\.stowColors) private var colors
    @State private var scanning = false
    @State private var pasting = false
    @State private var link = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            StowMark(size: 88)
            Text("Pair with your Mac")
                .font(.title2.weight(.bold))
                .foregroundStyle(colors.text)
                .padding(.top, 24)
            Text("On the Mac, open Stow › Phone › Pair a Phone, then scan the code it shows.")
                .font(.body)
                .foregroundStyle(colors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Group {
                if repository.pairState == .pairing {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Waiting for the Mac…").foregroundStyle(colors.secondaryText)
                    }
                } else {
                    VStack(spacing: 12) {
                        Button {
                            scanning = true
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                                .font(.headline)
                                .frame(maxWidth: 280)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        Button("Paste link") {
                            link = ""
                            pasting = true
                        }
                        .font(.body.weight(.medium))
                        Button("Use on its own instead") {
                            repository.switchToStandalone(keepChannels: false)
                        }
                        .font(.body.weight(.medium))
                        .padding(.top, 4)
                        if case .unpaired(let message?) = repository.pairState {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(colors.destructive)
                                .multilineTextAlignment(.center)
                                .padding(.top, 8)
                        }
                    }
                }
            }
            .padding(.top, 32)
            Spacer()
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
        .fullScreenCover(isPresented: $scanning) {
            QRScannerSheet { code in
                scanning = false
                Task { await repository.pair(code) }
            } onPaste: {
                scanning = false
                link = ""
                pasting = true
            }
            .sheetTheme(repository)
        }
        .alert("Paste link", isPresented: $pasting) {
            TextField("stow://pair?…", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Pair") {
                let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                Task { await repository.pair(text) }
            }
        } message: {
            Text("Paste the pairing link the Mac's code holds. It starts with stow://pair.")
        }
    }
}
