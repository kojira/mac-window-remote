import Testing
import CoreGraphics
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

/// D44: a tap is matched against the frames of the AX windows' title-bar buttons.
@Suite struct TitleButtonHitTests {
    // Logic's Settings panel: three 14 pt buttons at its top-left.
    let buttons = [
        TitleButtonPress.Candidate(kind: .close, frame: CGRect(x: 107, y: 206, width: 14, height: 14)),
        TitleButtonPress.Candidate(kind: .minimize, frame: CGRect(x: 127, y: 206, width: 14, height: 14)),
        TitleButtonPress.Candidate(kind: .zoom, frame: CGRect(x: 147, y: 206, width: 14, height: 14)),
    ]

    @Test func pointInsideAButtonHitsIt() {
        #expect(TitleButtonPress.hit(buttons, at: CGPoint(x: 114, y: 213)) == 0)
        #expect(TitleButtonPress.hit(buttons, at: CGPoint(x: 150, y: 210)) == 2)
    }

    @Test func slopOfThreePointsCounts() {
        #expect(TitleButtonPress.hit(buttons, at: CGPoint(x: 104, y: 203)) == 0)
        #expect(TitleButtonPress.hit(buttons, at: CGPoint(x: 103.5, y: 213)) == nil)
        #expect(TitleButtonPress.hit(buttons, at: CGPoint(x: 114, y: 224)) == nil)
    }

    @Test func pointOffEveryButtonHitsNothing() {
        #expect(TitleButtonPress.hit(buttons, at: CGPoint(x: 300, y: 400)) == nil)
        #expect(TitleButtonPress.hit([], at: CGPoint(x: 114, y: 213)) == nil)
    }

    @Test func smallestOverlappingFrameWins() {
        let overlapping = [
            TitleButtonPress.Candidate(kind: .fullScreen, frame: CGRect(x: 100, y: 200, width: 60, height: 20)),
            TitleButtonPress.Candidate(kind: .close, frame: CGRect(x: 107, y: 206, width: 14, height: 14)),
        ]
        #expect(TitleButtonPress.hit(overlapping, at: CGPoint(x: 114, y: 213)) == 1)
        #expect(TitleButtonPress.hit(overlapping, at: CGPoint(x: 150, y: 210)) == 0)
    }

    @Test func nearTopIsTheFortyPointBand() {
        let window = CGRect(x: 100, y: 200, width: 400, height: 300)
        #expect(TitleButtonPress.isNearTop(CGPoint(x: 110, y: 210), of: window))
        #expect(TitleButtonPress.isNearTop(CGPoint(x: 110, y: 240), of: window))
        #expect(!TitleButtonPress.isNearTop(CGPoint(x: 110, y: 241), of: window))
        #expect(!TitleButtonPress.isNearTop(CGPoint(x: 600, y: 210), of: window))
    }
}
