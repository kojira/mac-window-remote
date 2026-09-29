import IOKit.pwr_mgt

/// Keeps the display awake while a client is viewing (DESIGN.md D15).
final class DisplayAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false

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
}
