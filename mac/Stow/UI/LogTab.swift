import AppKit
import SwiftUI

/// Recent checks and errors, newest first.
struct LogTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<LogEntry.ID>()

    var body: some View {
        Table(model.log, selection: $selection) {
            TableColumn("") { entry in
                LevelIcon(level: entry.level)
            }
            .width(16)
            TableColumn("Time") { entry in
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130, max: 160)
            TableColumn("Message") { entry in
                Text(entry.message).help(entry.message)
            }
        }
        .contextMenu(forSelectionType: LogEntry.ID.self) { ids in
            Button("Copy") { copy(ids) }
        }
        .overlay {
            if model.log.isEmpty {
                ContentUnavailableView("No Log Entries", systemImage: "doc.text")
            }
        }
    }

    private func copy(_ ids: Set<LogEntry.ID>) {
        let text = model.log
            .filter { ids.contains($0.id) }
            .map { "\($0.date.ISO8601Format()) [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LevelIcon: View {
    let level: LogLevel

    var body: some View {
        switch level {
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

#if DEBUG
#Preview {
    LogTab()
        .environment(AppModel.preview)
        .frame(width: 640, height: 440)
}
#endif
