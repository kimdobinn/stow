import StowKit
import SwiftUI

/// The first screen: use Stow with the Mac (pair by QR code) or on its own.
struct ModeChooser: View {
    @Environment(Repository.self) private var repository
    @Environment(\.stowColors) private var colors

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                StowMark(size: 88)
                    .padding(.top, 72)
                Text("How do you want to use Stow?")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(colors.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                VStack(spacing: 14) {
                    ModeOption(title: "Use with my Mac",
                               subtitle: "Your Mac follows your channels and sends videos here. You pair with a QR code.",
                               systemImage: "desktopcomputer", primary: true) {
                        repository.chooseMac()
                    }
                    ModeOption(title: "Use on its own",
                               subtitle: "This phone follows channels and checks for new videos itself. Signing in to YouTube is optional.",
                               systemImage: "iphone", primary: false) {
                        repository.chooseStandalone()
                    }
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(colors.background)
    }
}

/// One of the two ways: a big button with what it means under its title.
private struct ModeOption: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let primary: Bool
    let action: () -> Void
    @Environment(\.stowColors) private var colors

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 30)
                    .foregroundStyle(primary ? .white : colors.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(primary ? .white : colors.text)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(primary ? .white.opacity(0.85) : colors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(primary ? colors.accent : colors.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(colors.divider, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
