import IOKit.pwr_mgt

/// Keeps the display awake while a client is viewing (DESIGN.md D15).
final class DisplayAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false
    private var activityId: IOPMAssertionID = 0

    func hold() {
        guard !held else { return }
        held = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "mac-window-remote viewing" as CFString,
            &id) == kIOReturnSuccess
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
    }

    /// Wakes a display that is already asleep when a viewer starts viewing (#49 part 1, D56):
    /// the idle-sleep assertion above does not turn a sleeping display on. The lock screen is
    /// left alone. Passing the same id again renews one activity assertion.
    func declareUserActivity() {
        IOPMAssertionDeclareUserActivity("mac-window-remote viewer started" as CFString,
                                         kIOPMUserActiveLocal, &activityId)
    }
}
