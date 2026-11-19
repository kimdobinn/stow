import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while the alarm is on, and wakes the display at alarm time.
@MainActor
final class PowerAssertions: PowerService {
    /// How long the display-wake (user activity) assertion is held before it's released and the
    /// normal display-sleep timer takes over again (mpv holds its own while a video plays).
    static let userActivityHold: Duration = .seconds(60)

    private var systemAssertion: IOPMAssertionID?
    private var userActivityAssertion = IOPMAssertionID(kIOPMNullAssertionID)
    private var userActivityRelease: Task<Void, Never>?

    var isHoldingSystemAwake: Bool { systemAssertion != nil }

    func holdSystemAwake(_ on: Bool) {
        if on, systemAssertion == nil {
            var id = IOPMAssertionID(kIOPMNullAssertionID)
            let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Stow morning alarm" as CFString, &id)
            if status == kIOReturnSuccess { systemAssertion = id }
        } else if !on, let id = systemAssertion {
            IOPMAssertionRelease(id)
            systemAssertion = nil
        }
    }

    func wakeDisplay() {
        // Re-declaring reuses (and refreshes) the same assertion id.
        let status = IOPMAssertionDeclareUserActivity("Stow morning alarm" as CFString, kIOPMUserActiveLocal,
                                                      &userActivityAssertion)
        guard status == kIOReturnSuccess else { return }
        userActivityRelease?.cancel()
        userActivityRelease = Task { [weak self] in
            try? await Task.sleep(for: Self.userActivityHold)
            guard !Task.isCancelled, let self else { return }
            IOPMAssertionRelease(self.userActivityAssertion)
            self.userActivityAssertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }
}
