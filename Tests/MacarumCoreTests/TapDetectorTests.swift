import Testing
@testable import MacarumCore

/// Wraps the detector so test lines can call it inside #expect.
private final class Pad {
    var detector = TapDetector()

    /// Taps ⌘ once: down at `t`, up `hold` seconds later. Returns whether it triggered.
    func tap(at t: Double, hold: Double = 0.08) -> Bool {
        _ = detector.modifiersChanged(to: .onlyTarget, at: t)
        return detector.modifiersChanged(to: .none, at: t + hold)
    }

    func modifiersChanged(to m: TapDetector.Modifiers, at t: Double) -> Bool {
        detector.modifiersChanged(to: m, at: t)
    }

    func keyPressed() { detector.keyPressed() }
}

@Suite struct TapDetectorTests {
    @Test func threeQuickTapsTrigger() {
        let d = Pad()
        #expect(!d.tap(at: 0))
        #expect(!d.tap(at: 0.2))
        #expect(d.tap(at: 0.4))
    }

    @Test func twoTapsDoNothing() {
        let d = Pad()
        #expect(!d.tap(at: 0))
        #expect(!d.tap(at: 0.2))
    }

    @Test func slowTapsDoNotAddUp() {
        let d = Pad()
        #expect(!d.tap(at: 0))
        #expect(!d.tap(at: 0.2))
        #expect(!d.tap(at: 1.0)) // gap too long: this is tap 1 again
        #expect(!d.tap(at: 1.2))
        #expect(d.tap(at: 1.4))
    }

    @Test func holdingIsNotATap() {
        let d = Pad()
        #expect(!d.tap(at: 0))
        #expect(!d.tap(at: 0.2))
        #expect(!d.tap(at: 0.4, hold: 0.6))
    }

    @Test func shortcutInBetweenResets() {
        let d = Pad()
        #expect(!d.tap(at: 0))
        // ⌘C: ⌘ down, C pressed, ⌘ up.
        _ = d.modifiersChanged(to: .onlyTarget, at: 0.2)
        d.keyPressed()
        #expect(!d.modifiersChanged(to: .none, at: 0.25))
        #expect(!d.tap(at: 0.35))
        #expect(!d.tap(at: 0.5))
    }

    @Test func otherModifierResets() {
        let d = Pad()
        #expect(!d.tap(at: 0))
        #expect(!d.tap(at: 0.2))
        _ = d.modifiersChanged(to: .other, at: 0.3) // ⌘⇧ together
        #expect(!d.modifiersChanged(to: .none, at: 0.35))
        #expect(!d.tap(at: 0.45))
    }

    @Test func fourthTapStartsANewCount() {
        let d = Pad()
        #expect(!d.tap(at: 0))
        #expect(!d.tap(at: 0.2))
        #expect(d.tap(at: 0.4))
        #expect(!d.tap(at: 0.6))
    }

    @Test func releaseWithoutPressIsIgnored() {
        let d = Pad()
        #expect(!d.modifiersChanged(to: .none, at: 0))
        #expect(!d.tap(at: 0.1))
    }
}
