import os
import StowKit
import UIKit
import UserNotifications

/// Keeps downloads going for as long as iOS lets a sideloaded app run, and says so when it stops.
///
/// iOS suspends an app soon after it leaves the screen: a running download gets a background
/// task (usually a few minutes at most), and the downloads background task (BackgroundWork) gets
/// more when iOS chooses, often overnight on power. When the time runs out the download is
/// paused cleanly, keeping what's downloaded so far, and a quiet notification says to open Stow.
/// Opening the app resumes it.
@MainActor
final class BackgroundDownloads {
    static let pausedNotification = "dev.stow.ios.downloads-paused"

    private let repository: Repository
    private var task: UIBackgroundTaskIdentifier = .invalid
    /// iOS gave the downloads background task: its time, not a background task's, is what counts.
    var inProcessingTask = false
    private let log = Logger(subsystem: "dev.stow.ios", category: "downloads")

    init(repository: Repository) {
        self.repository = repository
        repository.downloads.onBusyChange = { [weak self] busy in self?.busyChanged(busy) }
    }

    /// Provisional: notifications arrive quietly in Notification Center, without asking first.
    func requestQuietNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .provisional]) { _, _ in }
    }

    /// On screen again: downloads go on, and the "paused" note is no longer true.
    func appBecameActive() {
        repository.downloads.resume()
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.pausedNotification])
        center.removePendingNotificationRequests(withIdentifiers: [Self.pausedNotification])
    }

    /// iOS is about to suspend the app (a background task ran out of time).
    func timeRunningOut() {
        let downloads = repository.downloads
        guard !downloads.queuedIds.isEmpty else { return }
        downloads.suspend()
        BackgroundWork.scheduleDownloads()
        guard UIApplication.shared.applicationState != .active else { return }
        log.info("Background time ran out with \(downloads.queuedIds.count) downloads waiting")
        let count = downloads.queuedIds.count
        let content = UNMutableNotificationContent()
        content.title = "Downloads paused"
        content.body = count == 1 ? "Open Stow to finish the download." : "Open Stow to finish \(count) downloads."
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: Self.pausedNotification, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A download runs: ask iOS for time to finish it after the app leaves the screen.
    private func busyChanged(_ busy: Bool) {
        if busy {
            guard task == .invalid else { return }
            task = UIApplication.shared.beginBackgroundTask(withName: "Download") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.inProcessingTask { self.timeRunningOut() }
                    self.endTask()
                }
            }
        } else {
            endTask()
        }
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
