import Testing
@testable import FnVoiceCore

@Suite struct FnKeyTrackerTests {
    let fnDown = KeyEventInput(kind: .flagsChanged, keyCode: 63, fnFlag: true)
    let fnUp = KeyEventInput(kind: .flagsChanged, keyCode: 63, fnFlag: false)

    @Test func bareFnIsClaimedAndSuppressed() {
        var t = FnKeyTracker()
        #expect(t.handle(fnDown, dictationCancellable: false) == (.suppress, .fnDown))
        #expect(t.handle(fnUp, dictationCancellable: true) == (.suppress, .fnUp))
        #expect(!t.fnHeld)
    }

    @Test func fnWithOtherModifierPassesThrough() {
        var t = FnKeyTracker()
        let cmdFn = KeyEventInput(kind: .flagsChanged, keyCode: 63, fnFlag: true, otherModifiers: true)
        #expect(t.handle(cmdFn, dictationCancellable: false) == (.passThrough, nil))
        #expect(t.handle(fnUp, dictationCancellable: false) == (.passThrough, nil))
    }

    @Test func keyWhileFnHeldIsPassedThroughAsCombo() {
        var t = FnKeyTracker()
        _ = t.handle(fnDown, dictationCancellable: false)
        let upArrow = KeyEventInput(kind: .keyDown, keyCode: 126, fnFlag: true)
        #expect(t.handle(upArrow, dictationCancellable: false) == (.passThrough, .comboKey))
        let f5 = KeyEventInput(kind: .keyDown, keyCode: 96, fnFlag: true)
        #expect(t.handle(f5, dictationCancellable: false) == (.passThrough, .comboKey))
    }

    @Test func fnsOwnRepeatEventsFollowTheClaim() {
        var t = FnKeyTracker()
        let fnKeyDown = KeyEventInput(kind: .keyDown, keyCode: 63, fnFlag: true)
        let fnKeyUp = KeyEventInput(kind: .keyUp, keyCode: 63, fnFlag: true)
        // A stray release with nothing held, and Fn's own key events while released, are the system's.
        #expect(t.handle(fnUp, dictationCancellable: false) == (.passThrough, nil))
        #expect(t.handle(fnKeyDown, dictationCancellable: false) == (.passThrough, nil))
        #expect(t.handle(fnKeyUp, dictationCancellable: false) == (.passThrough, nil))
        // While a claimed press is held, its repeats are swallowed and mean nothing new.
        _ = t.handle(fnDown, dictationCancellable: false)
        #expect(t.handle(fnDown, dictationCancellable: false) == (.suppress, nil))
        #expect(t.handle(fnKeyDown, dictationCancellable: false) == (.suppress, nil))
        #expect(t.handle(fnKeyUp, dictationCancellable: false) == (.suppress, nil))
        #expect(t.handle(fnUp, dictationCancellable: false) == (.suppress, .fnUp))
    }

    @Test func unclaimedFnRepeatsPassThroughAndClaimNothing() {
        var t = FnKeyTracker()
        let cmdFn = KeyEventInput(kind: .flagsChanged, keyCode: 63, fnFlag: true, otherModifiers: true)
        _ = t.handle(cmdFn, dictationCancellable: false)
        #expect(t.handle(cmdFn, dictationCancellable: false) == (.passThrough, nil))
        let a = KeyEventInput(kind: .keyDown, keyCode: 0, fnFlag: true, otherModifiers: true)
        #expect(t.handle(a, dictationCancellable: false) == (.passThrough, nil))
        let shift = KeyEventInput(kind: .flagsChanged, keyCode: 56, fnFlag: true, otherModifiers: true)
        #expect(t.handle(shift, dictationCancellable: false) == (.passThrough, nil))
        // Fn's own key events are swallowed while it is held at all, claimed or not.
        #expect(t.handle(KeyEventInput(kind: .keyDown, keyCode: 63, fnFlag: true), dictationCancellable: false) == (.suppress, nil))
        #expect(t.handle(KeyEventInput(kind: .keyUp, keyCode: 63, fnFlag: true), dictationCancellable: false) == (.suppress, nil))
    }

    @Test func arrowKeysCarryFnFlagButAreNotFn() {
        var t = FnKeyTracker()
        let arrow = KeyEventInput(kind: .keyDown, keyCode: 123, fnFlag: true)
        #expect(t.handle(arrow, dictationCancellable: false) == (.passThrough, nil))
        #expect(!t.fnHeld)
    }

    @Test func modifierAddedWhileFnHeldIsCombo() {
        var t = FnKeyTracker()
        _ = t.handle(fnDown, dictationCancellable: false)
        let shift = KeyEventInput(kind: .flagsChanged, keyCode: 56, fnFlag: true, otherModifiers: true)
        #expect(t.handle(shift, dictationCancellable: false) == (.passThrough, .comboKey))
    }

    @Test func escapeSuppressedOnlyWhenCancellable() {
        var t = FnKeyTracker()
        let escDown = KeyEventInput(kind: .keyDown, keyCode: 53, fnFlag: false)
        let escUp = KeyEventInput(kind: .keyUp, keyCode: 53, fnFlag: false)
        #expect(t.handle(escDown, dictationCancellable: false) == (.passThrough, nil))
        #expect(t.handle(escUp, dictationCancellable: false) == (.passThrough, nil))
        #expect(t.handle(escDown, dictationCancellable: true) == (.suppress, .escape))
        // The matching key-up is swallowed even if dictation already ended.
        #expect(t.handle(escUp, dictationCancellable: false) == (.suppress, nil))
    }

    @Test func globeKeyCodeIsTreatedAsFn() {
        var t = FnKeyTracker()
        let globe = KeyEventInput(kind: .flagsChanged, keyCode: 179, fnFlag: true)
        #expect(t.handle(globe, dictationCancellable: false) == (.suppress, .fnDown))
        let globeKey = KeyEventInput(kind: .keyDown, keyCode: 179, fnFlag: true)
        #expect(t.handle(globeKey, dictationCancellable: false) == (.suppress, nil))
    }

    @Test func ordinaryTypingIsUntouched() {
        var t = FnKeyTracker()
        let a = KeyEventInput(kind: .keyDown, keyCode: 0, fnFlag: false)
        #expect(t.handle(a, dictationCancellable: true) == (.passThrough, nil))
    }

    @Test func resyncReportsAMissedFnUp() {
        var t = FnKeyTracker()
        _ = t.handle(fnDown, dictationCancellable: false)
        #expect(t.resync(fnPhysicallyDown: false) == .fnUp)
        #expect(!t.fnHeld)
        #expect(t.handle(fnDown, dictationCancellable: false) == (.suppress, .fnDown))
    }

    @Test func resyncKeepsAStillHeldFn() {
        // The tap was disabled mid-dictation but Fn is still down: recording must go on.
        var t = FnKeyTracker()
        _ = t.handle(fnDown, dictationCancellable: false)
        #expect(t.resync(fnPhysicallyDown: true) == nil)
        #expect(t.fnHeld)
    }

    @Test func resyncWithoutAClaimedPressReportsNothing() {
        var t = FnKeyTracker()
        #expect(t.resync(fnPhysicallyDown: false) == nil)
    }
}
