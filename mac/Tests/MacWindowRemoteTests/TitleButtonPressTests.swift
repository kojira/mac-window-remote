import Testing
@testable import MacWindowRemote

/// D44: a left click on a title-bar button is an AX press; anything else stays a click.
@Suite struct TitleButtonPressTests {
    @Test(arguments: ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"])
    func titleBarButtonIsPressed(_ subrole: String) {
        #expect(TitleButtonPress.decision(subrole: subrole, parentSubrole: nil) == .press)
        #expect(TitleButtonPress.decision(subrole: nil, parentSubrole: subrole) == .press)
        #expect(TitleButtonPress.decision(subrole: "AXUnknown", parentSubrole: subrole) == .press)
    }

    @Test func otherElementsAreClicked() {
        #expect(TitleButtonPress.decision(subrole: nil, parentSubrole: nil) == .click)
        #expect(TitleButtonPress.decision(subrole: "AXStandardWindow", parentSubrole: nil) == .click)
        #expect(TitleButtonPress.decision(subrole: "AXCloseButtonX", parentSubrole: "AXDialog") == .click)
    }
}
