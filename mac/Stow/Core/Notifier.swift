import AppKit
import UserNotifications

/// What AppModel needs from notifications; tests substitute a recorder.
@MainActor
protocol UserNotifying: AnyObject {
    /// Returns whether notifications are allowed.
    @discardableResult func requestAuthorization() async -> Bool
    /// One summary notification for everything found in a check.
    func notifyNewVideos(_ videos: [Video])
    /// Rate-limited per title.
    func notifyProblem(title: String, body: String)
}

/// macOS user notifications for new videos and problems.
@MainActor
final class Notifier: NSObject, UserNotifying, UNUserNotificationCenterDelegate {
    /// The same problem is reported at most this often.
    static let problemInterval: TimeInterval = 6 * 60 * 60
    private nonisolated static let urlKey = "url"

    private var lastProblemDates: [String: Date] = [:]
    private var center: UNUserNotificationCenter { .current() }

    @discardableResult
    func requestAuthorization() async -> Bool {
        center.delegate = self
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func notifyNewVideos(_ videos: [Video]) {
        guard let first = videos.first else { return }
        let content = UNMutableNotificationContent()
        if videos.count == 1 {
            content.title = first.channelTitle
            content.body = (first.isMembersOnly ? "Members only: " : "") + first.title
            content.userInfo = [Self.urlKey: first.watchURL.absoluteString]
        } else {
            content.title = "\(videos.count) new videos"
            var lines = videos.prefix(3).map { "\($0.channelTitle): \($0.title)" }
            if videos.count > 3 { lines.append("and \(videos.count - 3) more") }
            content.body = lines.joined(separator: "\n")
        }
        content.sound = .default
        post(content)
    }

    func notifyProblem(title: String, body: String) {
        if let last = lastProblemDates[title], Date.now.timeIntervalSince(last) < Self.problemInterval { return }
        lastProblemDates[title] = .now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(content)
    }

    private func post(_ content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Menu bar apps are often frontmost while a Settings window is open; show banners anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let string = response.notification.request.content.userInfo[Self.urlKey] as? String,
              let url = URL(string: string) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
