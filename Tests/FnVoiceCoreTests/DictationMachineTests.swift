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
        #expect(m.send(.transcriptFinal(session: 1, text: " 你好 ", refine: .none)) == [.inject(session: 1, text: "你好")])
        #expect(m.send(.injected(session: 1, notice: nil)) == [.hideCapsule])
        #expect(m.phase == .idle)
    }

    @Test func happyPathWithRefinement() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        #expect(m.send(.transcriptFinal(session: s, text: "配森", refine: .beforeTyping)) == [.refine(session: s, text: "配森")])
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
        #expect(m.send(.transcriptFinal(session: s, text: "late", refine: .none)) == [])

        (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "x", refine: .beforeTyping))
        #expect(m.send(.cancel) == [.cancelRefine, .hideCapsule])
        #expect(m.phase == .idle)
    }

    @Test func escapeDuringInjectionIsTooLate() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "x", refine: .none))
        #expect(m.send(.cancel) == [])
        #expect(m.phase == .injecting)
        #expect(!m.phase.isCancellable)
    }

    @Test func fnDuringRefiningIsIgnored() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "x", refine: .beforeTyping))
        #expect(m.send(.fnDown) == [])
        #expect(m.send(.fnUp) == [])
        #expect(m.phase == .refining)
        #expect(m.session == s)
    }

    @Test func staleRefinementFromCancelledSessionCannotLeakIntoNewOne() {
        var (m, old) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: old, text: "old", refine: .beforeTyping))
        _ = m.send(.cancel)

        _ = m.send(.fnDown)
        let new = m.session
        _ = m.send(.armElapsed(session: new))
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: new, text: "new", refine: .beforeTyping))
        #expect(m.send(.refined(session: old, text: "OLD RESULT")) == [])
        #expect(m.send(.refined(session: new, text: "new")) == [.inject(session: new, text: "new")])
    }

    @Test func emptyTranscriptInjectsNothing() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        #expect(m.send(.transcriptFinal(session: s, text: "  \n", refine: .beforeTyping)) == [.hideCapsule])
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
        _ = m.send(.transcriptFinal(session: s, text: "x", refine: .none))
        #expect(m.send(.injected(session: s, notice: "App changed")) == [.notify("App changed")])
    }

    // MARK: - Type first, refine in place

    /// A dictation typed raw and waiting for the LLM.
    func typedInPlace() -> (DictationMachine, Int) {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "配森", refine: .afterTyping))
        _ = m.send(.injected(session: s, notice: nil))
        return (m, s)
    }

    @Test func inPlaceTypesRawAtOnceAndSwapsTheAnswerIn() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        // Refinement starts first so the network overlaps the paste.
        #expect(m.send(.transcriptFinal(session: s, text: " 配森 ", refine: .afterTyping))
            == [.refine(session: s, text: "配森"), .inject(session: s, text: "配森")])
        #expect(m.phase == .injecting)
        #expect(m.send(.injected(session: s, notice: nil)) == [.hideCapsule])
        #expect(m.phase == .refiningInPlace)
        #expect(m.send(.refined(session: s, text: "Python")) == [.replace(session: s, text: "Python")])
        #expect(m.phase == .replacing)
        #expect(m.send(.replaced(session: s, notice: nil)) == [])
        #expect(m.phase == .idle)
    }

    @Test func answerArrivingDuringThePasteIsAppliedAfterIt() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "配森", refine: .afterTyping))
        #expect(m.send(.refined(session: s, text: "Python")) == [])
        #expect(m.phase == .injecting)
        #expect(m.send(.injected(session: s, notice: "Couldn't restore your input method"))
            == [.notify("Couldn't restore your input method"), .replace(session: s, text: "Python")])
        #expect(m.phase == .replacing)
    }

    @Test func refusedInjectionDropsThePendingAnswer() {
        var (m, s) = recording()
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: s, text: "配森", refine: .afterTyping))
        #expect(m.send(.injected(session: s, notice: "App changed", typed: false)) == [.cancelRefine, .notify("App changed")])
        #expect(m.phase == .idle)
        #expect(m.send(.refined(session: s, text: "Python")) == [])
    }

    @Test func escapeIsNotClaimedOnceTextIsOut() {
        var (m, s) = typedInPlace()
        #expect(!m.phase.isCancellable)
        #expect(m.send(.cancel) == [])
        #expect(m.phase == .refiningInPlace)
        _ = m.send(.refined(session: s, text: "Python"))
        #expect(!m.phase.isCancellable)
        #expect(m.send(.cancel) == [])
    }

    @Test func fnWhileWaitingInPlaceAbandonsTheSwapAndStartsOver() {
        var (m, old) = typedInPlace()
        #expect(m.send(.fnDown) == [.cancelRefine, .scheduleArm(session: old + 1)])
        #expect(m.phase == .arming)
        let new = m.session
        _ = m.send(.armElapsed(session: new))
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: new, text: "new", refine: .afterTyping))
        _ = m.send(.injected(session: new, notice: nil))
        // The old answer can't reach the new dictation's text.
        #expect(m.send(.refined(session: old, text: "OLD")) == [])
        #expect(m.phase == .refiningInPlace)
        #expect(m.send(.refined(session: new, text: "NEW")) == [.replace(session: new, text: "NEW")])
    }

    @Test func fnDuringTheSwapIsIgnored() {
        var (m, s) = typedInPlace()
        _ = m.send(.refined(session: s, text: "Python"))
        #expect(m.send(.fnDown) == [])
        #expect(m.phase == .replacing)
        #expect(m.send(.replaced(session: s, notice: "x")) == [.notify("x")])
        #expect(m.phase == .idle)
    }

    @Test func inPlaceStateDoesNotLeakIntoTheNextDictation() {
        var (m, s) = typedInPlace()
        _ = m.send(.refined(session: s, text: "Python"))
        _ = m.send(.replaced(session: s, notice: nil))
        _ = m.send(.fnDown)
        let t = m.session
        _ = m.send(.armElapsed(session: t))
        _ = m.send(.fnUp)
        _ = m.send(.transcriptFinal(session: t, text: "x", refine: .beforeTyping))
        #expect(m.send(.refined(session: t, text: "y")) == [.inject(session: t, text: "y")])
        // A plain injection ends the dictation; no in-place phase is entered.
        #expect(m.send(.injected(session: t, notice: nil)) == [.hideCapsule])
        #expect(m.phase == .idle)
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
        #expect(m.send(.transcriptFinal(session: 2, text: "长段口述", refine: .none)) == [.inject(session: 2, text: "长段口述")])
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
