import SwiftUI

/// "Checked 7 min ago ✓", "Checking…", "No channels to check", or the last check's error in red.
struct CheckStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if model.isChecking {
            Text("Checking…").foregroundStyle(.secondary)
        } else if model.channels.isEmpty {
            Text("No channels to check").foregroundStyle(.secondary)
        } else if let check = model.lastCheck {
            let ago = check.finishedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            if check.isOK {
                HStack(spacing: 4) {
                    Text("Checked \(ago)").foregroundStyle(.secondary)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Text(failureText(check, ago: ago))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(check.errors.joined(separator: "\n"))
            }
        } else {
            Text("Not checked yet").foregroundStyle(.secondary)
        }
    }

    private func failureText(_ check: CheckResult, ago: String) -> String {
        let first = check.errors.first ?? ""
        let more = check.errors.count > 1 ? " (+\(check.errors.count - 1) more)" : ""
        return "Check failed \(ago): \(first)\(more)"
    }
}
