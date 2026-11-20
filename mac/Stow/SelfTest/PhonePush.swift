#if DEBUG
import Foundation

/// `Stow --phone-push` (Debug builds only): sends a "sync" push to every paired phone and says
/// whether FCM accepted each token.
@MainActor
enum PhonePush {
    static let argument = "--phone-push"

    static func run() async -> Bool {
        do {
            let backend = try FirebaseBackend(keyFile: AppPaths.firebaseKeyFile)
            let members = try await backend.members()
            if members.isEmpty { print("no paired phones") }
            for member in members {
                guard let token = member.fcmToken else {
                    print("\(member.name): no push token")
                    continue
                }
                let sent = try await backend.push(["type": "sync"], to: token)
                print("\(member.name): \(sent ? "push accepted" : "token invalid")")
            }
            return true
        } catch {
            print("failed: \(error.logDescription)")
            return false
        }
    }
}
#endif
