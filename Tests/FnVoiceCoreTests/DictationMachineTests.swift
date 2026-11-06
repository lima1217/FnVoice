import Testing
@testable import FnVoiceCore

@Suite struct DictationMachineTests {
    /// Drives a fresh machine to `recording` and returns it with its session id.
    func recording() -> (DictationMachine, Int) {
        var m = DictationMachine()
        _ = m.send(.fnDown)
        let s = m.session
        _ = m.send(.armElapsed(session: s))
        return (m, s)
    }

    @Test func happyPathWithoutRefinement() {
        var m = DictationMachine()
        #expect(m.send(.fnDown) == [.scheduleArm(session: 1)])
        #expect(m.phase == .arming)
        #expect(m.send(.armElapsed(session: 1)) == [.startCapture(session: 1)])
        #expect(m.send(.fnUp) == [.stopCapture(session: 1)])
        #expect(m.phase == .finalizing)
        #expect(m.send(.transcriptFinal(session: 1, text: " 你好 ", refine: false)) == [.inject(session: 1, text: "你好")])
        #expect(m.send(.injected(session: 1, notice: nil)) == [.hideCapsule])
        #expect(m.phase == .idle)
    }

    @Test func happyPathWithRefinement() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        #expect(m.send(.transcriptFinal(session: s, text: "配森", refine: true)) == [.refine(session: s, text: "配森")])
        #expect(m.phase == .refining)
        #expect(m.send(.refined(session: s, text: "Python")) == [.inject(session: s, text: "Python")])
        #expect(m.phase == .injecting)
    }

    @Test func quickTapNeverStartsRecording() {
        var m = DictationMachine()
        _ = m.send(.fnDown)
        #expect(m.send(.fnUp) == [.cancelArm, .scheduleTapWindow(session: 1)])
        #expect(m.phase == .tapped)
        #expect(m.send(.armElapsed(session: 1)) == []) // timer that fired late is ignored
        #expect(m.send(.tapWindowElapsed(session: 1)) == [])
        #expect(m.phase == .idle)
    }

    @Test func comboKeyWhileArmingAborts() {
        var m = DictationMachine()
        _ = m.send(.fnDown)
        #expect(m.send(.comboKey) == [.cancelArm])
        #expect(m.phase == .idle)
    }

    @Test func comboKeyWhileRecordingIsIgnored() {
        var (m, _) = recording()
        #expect(m.send(.comboKey) == [])
        #expect(m.phase == .recording)
    }

    @Test func escapeCancelsEveryCancellablePhase() {
        var (m, s) = recording()
        #expect(m.send(.cancel) == [.abortCapture, .hideCapsule])

        (m, s) = recording()
        _ = m.send(.fnUp)
        #expect(m.send(.cancel) == [.abortCapture, .hideCapsule])
        #expect(m.send(.transcriptFinal(session: s, text: "late", refine: false)) == [])

        (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "x", refine: true))
        #expect(m.send(.cancel) == [.cancelRefine, .hideCapsule])
        #expect(m.phase == .idle)
    }

    @Test func escapeDuringInjectionIsTooLate() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "x", refine: false))
        #expect(m.send(.cancel) == [])
        #expect(m.phase == .injecting)
        #expect(!m.phase.isCancellable)
    }

    @Test func fnDuringRefiningIsIgnored() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "x", refine: true))
        #expect(m.send(.fnDown) == [])
        #expect(m.send(.fnUp) == [])
        #expect(m.phase == .refining)
        #expect(m.session == s)
    }

    @Test func staleRefinementFromCancelledSessionCannotLeakIntoNewOne() {
        var (m, old) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: old, text: "old", refine: true))
        _ = m.send(.cancel)

        _ = m.send(.fnDown)
        let new = m.session
        _ = m.send(.armElapsed(session: new))
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: new, text: "new", refine: true))
        #expect(m.send(.refined(session: old, text: "OLD RESULT")) == [])
        #expect(m.send(.refined(session: new, text: "new")) == [.inject(session: new, text: "new")])
    }

    @Test func emptyTranscriptInjectsNothing() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        #expect(m.send(.transcriptFinal(session: s, text: "  \n", refine: true)) == [.hideCapsule])
        #expect(m.phase == .idle)
    }

    @Test func captureFailureNotifies() {
        var (m, s) = recording()
        #expect(m.send(.captureFailed(session: s, message: "no mic")) == [.abortCapture, .notify("no mic")])
        #expect(m.phase == .idle)
    }

    @Test func injectionNoticeIsShown() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "x", refine: false))
        #expect(m.send(.injected(session: s, notice: "App changed")) == [.notify("App changed")])
    }
}

@Suite struct LockedRecordingTests {
    /// Tap Fn, then press it again within the tap window.
    func doubleTapped() -> (DictationMachine, [DictationEffect]) {
        var m = DictationMachine()
        _ = m.send(.fnDown)
        _ = m.send(.fnUp)
        let effects = m.send(.fnDown)
        return (m, effects)
    }

    @Test func doubleTapStartsLockedRecordingAtOnce() {
        let (m, effects) = doubleTapped()
        #expect(effects == [.cancelTapWindow, .startCapture(session: 2)])
        #expect(m.phase == .recording)
        #expect(m.locked)
    }

    @Test func releasingFnKeepsRecordingAndTheNextPressFinishes() {
        var (m, _) = doubleTapped()
        #expect(m.send(.fnUp) == [])
        #expect(m.phase == .recording)
        #expect(m.send(.fnDown) == [.stopCapture(session: 2)])
        #expect(m.phase == .finalizing)
        #expect(!m.locked)
        #expect(m.send(.fnUp) == []) // the release of the stopping press
        #expect(m.send(.transcriptFinal(session: 2, text: "长段口述", refine: false)) == [.inject(session: 2, text: "长段口述")])
    }

    @Test func escapeCancelsLockedRecording() {
        var (m, _) = doubleTapped()
        _ = m.send(.fnUp)
        #expect(m.send(.cancel) == [.abortCapture, .hideCapsule])
        #expect(m.phase == .idle)
        #expect(!m.locked)
    }

    @Test func comboOnTheLockingPressAbortsInsteadOfLockingTheMic() {
        // Tap Fn, then Fn+← soon after: a shortcut, not a dictation.
        var (m, _) = doubleTapped()
        #expect(m.send(.comboKey) == [.abortCapture, .hideCapsule])
        #expect(m.phase == .idle)
        #expect(!m.locked)
    }

    @Test func comboAfterTheLockingPressIsReleasedIsIgnored() {
        var (m, _) = doubleTapped()
        _ = m.send(.fnUp)
        #expect(m.send(.comboKey) == [])
        #expect(m.phase == .recording)
    }

    @Test func secondPressAfterTheWindowIsAnOrdinaryHold() {
        var m = DictationMachine()
        _ = m.send(.fnDown)
        _ = m.send(.fnUp)
        _ = m.send(.tapWindowElapsed(session: 1))
        #expect(m.send(.fnDown) == [.scheduleArm(session: 2)])
        #expect(m.phase == .arming)
        #expect(!m.locked)
    }

    @Test func staleTapWindowTimerIsIgnored() {
        var (m, _) = doubleTapped()
        #expect(m.send(.tapWindowElapsed(session: 1)) == [])
        #expect(m.phase == .recording)
    }

    @Test func escapeDuringTheTapWindowJustCloses() {
        var m = DictationMachine()
        _ = m.send(.fnDown)
        _ = m.send(.fnUp)
        #expect(!m.phase.isCancellable) // Esc must still reach the frontmost app
        #expect(m.send(.cancel) == [.cancelTapWindow])
        #expect(m.phase == .idle)
    }

    @Test func finishStopsLockedAndHeldRecording() {
        var (m, _) = doubleTapped()
        #expect(m.send(.finish(session: 2)) == [.stopCapture(session: 2)])
        #expect(m.phase == .finalizing)

        m = DictationMachine()
        _ = m.send(.fnDown)
        _ = m.send(.armElapsed(session: 1))
        #expect(m.send(.finish(session: 0)) == []) // stale
        #expect(m.send(.finish(session: 1)) == [.stopCapture(session: 1)])
    }

    @Test func heldRecordingIsNotLocked() {
        var m = DictationMachine()
        _ = m.send(.fnDown)
        _ = m.send(.armElapsed(session: 1))
        #expect(!m.locked)
        #expect(m.send(.fnUp) == [.stopCapture(session: 1)])
    }
}
