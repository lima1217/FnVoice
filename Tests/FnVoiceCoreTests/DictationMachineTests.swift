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
        #expect(m.send(.fnUp) == [.cancelArm])
        #expect(m.send(.armElapsed(session: 1)) == []) // timer that fired late is ignored
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
