import StowKit
import SwiftUI

/// The iPhone app. Launch with -demo for sample data instead of Firebase, or -ytdlp-selftest to
/// check yt-dlp (see YtDlpSelfTest).
@main
struct StowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var selfTest = YtDlpSelfTest()
    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.repository)
                .environment(services.shell)
                .environment(services.player)
                .environment(selfTest)
                .onOpenURL { services.open($0) }
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains(YtDlpSelfTest.launchArgument) {
                        await selfTest.run(javaScript: !arguments.contains("-ytdlp-nojs"), debug: arguments.contains("-ytdlp-debug"))
                        if arguments.contains("-ytdlp-selftest-exit") { exit(0) }
                    } else {
                        LaunchRoutes.apply(to: services.shell, repository: services.repository)
                        // Loads Python and yt-dlp while the first screen shows.
                        try? await YtDlp.shared.prepare()
                    }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            services.scenePhaseChanged(phase)
        }
    }
}

/// The yt-dlp self-test (Settings › yt-dlp), for checking a build on a phone.
struct YtDlpDebugView: View {
    @Environment(YtDlpSelfTest.self) private var selfTest
    @Environment(\.stowColors) private var colors
    @State private var javaScript = true

    var body: some View {
        List {
            Section {
                Toggle("Solve YouTube's challenges", isOn: $javaScript)
                    .tint(.green)
                Button(selfTest.running ? "Checking…" : "Check yt-dlp") {
                    Task { await selfTest.run(javaScript: javaScript) }
                }
                .disabled(selfTest.running)
            } footer: {
                Text("Plays and downloads a few public videos.")
            }
            .listRowBackground(colors.raised)
            Section {
                ForEach(selfTest.steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: step.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(step.passed ? .green : .red)
                            Text(step.name).font(.headline)
                            Spacer()
                            Text(String(format: "%.1f s", step.seconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .listRowBackground(colors.raised)
        }
        .scrollContentBackground(.hidden)
        .background(colors.groupedBackground)
        .navigationTitle("yt-dlp")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { YtDlpDebugView() }
        .environment(YtDlpSelfTest())
}
