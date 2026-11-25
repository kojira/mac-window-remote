import ApplicationServices

/// `TerminalTextSource` over Accessibility (D67): finds the AX window that matches the CG
/// window (WindowFocuser's frame-and-title match) and reads the `AXValue` of its text area.
/// Only attribute reads: no action is performed and no attribute is set.
struct AXTerminalTextSource: TerminalTextSource {
    func read(windowId: UInt32, pid: pid_t) -> TerminalTextRead {
        guard Permissions.accessibility else { return .axDenied }
        guard let bounds = WindowCatalog.currentBounds(windowId) else { return .windowGone }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXMenuSource.messagingTimeout)
        guard let window = WindowFocuser.axWindow(app: app, bounds: bounds, title: WindowCatalog.windowName(windowId)),
              let text = TerminalTextArea.text(in: window, tree: AXTree()) else { return .noText }
        return .text(text)
    }
}

private struct AXTree: TerminalTextTree {
    func role(_ element: AXUIElement) -> String? { AXRead.attribute(element, kAXRoleAttribute) }
    func children(_ element: AXUIElement) -> [AXUIElement] { AXRead.children(element) }
    func stringValue(_ element: AXUIElement) -> String? { AXRead.attribute(element, kAXValueAttribute) }
}
