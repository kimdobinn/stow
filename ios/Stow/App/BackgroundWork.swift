import BackgroundTasks
import os
import StowKit

/// With no push on a sideloaded iPhone, iOS wakes the app now and then instead: a refresh polls
/// the Mac's Firebase (new videos join the download queue), and a processing task, asked for when
/// downloads are waiting, gives them time to run.
@MainActor
enum BackgroundWork {
    static let refreshID = "dev.stow.ios.refresh"
    static let downloadsID = "dev.stow.ios.downloads"
    /// iOS decides when; this is the soonest it may.
    static let refreshInterval: TimeInterval = 30 * 60
    private static let log = Logger(subsystem: "dev.stow.ios", category: "background")

    static func register(_ services: AppServices) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: .main) { task in
            MainActor.assumeIsolated { run(task, services: services, downloads: false) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: downloadsID, using: .main) { task in
            MainActor.assumeIsolated { run(task, services: services, downloads: true) }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        submit(request)
    }

    static func scheduleDownloads() {
        let request = BGProcessingTaskRequest(identifier: downloadsID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        submit(request)
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Always the case in the simulator, and when Background App Refresh is off.
            log.info("Couldn't schedule \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func run(_ task: BGTask, services: AppServices, downloads: Bool) {
        if !downloads { scheduleRefresh() }
        let repository = services.repository
        let keeper = services.backgroundDownloads
        let finish = Finish(task)
        if downloads {
            keeper.inProcessingTask = true
            repository.downloads.resume()
        }
        let work = Task { @MainActor in
            let ok = await repository.backgroundRefresh()
            if downloads { await repository.downloads.waitUntilIdle() }
            if downloads { keeper.inProcessingTask = false }
            finish.complete(ok)
            if downloads, !repository.downloads.queuedIds.isEmpty { scheduleDownloads() }
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in
                if downloads {
                    keeper.inProcessingTask = false
                    // Paused cleanly, keeping what's down, rather than cut off when iOS suspends the app.
                    keeper.timeRunningOut()
                }
                finish.complete(false)
                if downloads { scheduleDownloads() }
            }
        }
    }

    /// Tells iOS the task is done, once.
    private final class Finish {
        nonisolated(unsafe) private let task: BGTask
        private var done = false

        init(_ task: BGTask) {
            self.task = task
        }

        func complete(_ success: Bool) {
            guard !done else { return }
            done = true
            task.setTaskCompleted(success: success)
        }
    }
}
