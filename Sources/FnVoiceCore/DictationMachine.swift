import Foundation

/// Lifecycle of one dictation. `arming` is the 150ms window between Fn-down and the
/// moment we commit to recording, so a quick Fn tap or an Fn+key combo never starts the mic.
///
/// Two ways through refinement:
/// - `refining` → `injecting`: wait for the LLM, then type its answer (used when the target field
///   can't be read back through Accessibility, so a later swap would be impossible).
/// - `injecting` → `refiningInPlace` → `replacing`: type the raw text at once, and when the LLM
///   answers something different, swap it in place. The user never waits for the network.
///
/// Double-tapping Fn locks recording for long dictation: a quick tap opens `tapped` for
/// `DictationMachine.tapWindow`, and pressing Fn again inside it starts recording at once, with
/// `locked` set. Releasing Fn then keeps recording; the next Fn press finishes, Esc cancels.
public enum DictationPhase: Equatable, Sendable {
    case idle, arming, recording, finalizing, refining, injecting
    /// The raw text is already typed; the LLM is still answering.
    case refiningInPlace
    /// The LLM's answer is being swapped in for the typed raw text.
    case replacing
    /// Fn was tapped; another press within the tap window locks recording.
    case tapped

    /// Esc can abort these phases. Once text has gone out it is too late to take it back, and
    /// claiming Esc then would steal it from the app the user is already back in.
    public var isCancellable: Bool {
        switch self {
        case .arming, .recording, .finalizing, .refining: true
        case .idle, .injecting, .refiningInPlace, .replacing, .tapped: false
        }
    }
}

/// What to do with the LLM for one transcript.
public enum RefinementPlan: Equatable, Sendable {
    case none
    /// Hold the text until the LLM answers, then type the answer.
    case beforeTyping
    /// Type the raw text now; replace it in place if the LLM changes it.
    case afterTyping
}

public enum DictationEvent: Equatable, Sendable {
    case fnDown
    case fnUp
    /// Another key was pressed while Fn was held (Fn+arrow, Fn+F-key, Fn+Shift...).
    case comboKey
    case cancel
    case armElapsed(session: Int)
    case tapWindowElapsed(session: Int)
    /// Stop recording and transcribe, as Fn-up would, even when recording is locked
    /// (duration limits use it).
    case finish(session: Int)
    case transcriptFinal(session: Int, text: String, refine: RefinementPlan)
    case refined(session: Int, text: String)
    /// `typed` is false when injection was refused (secure input, app changed) and nothing went out.
    case injected(session: Int, notice: String?, typed: Bool = true)
    case replaced(session: Int, notice: String?)
    case captureFailed(session: Int, message: String)
}

public enum DictationEffect: Equatable, Sendable {
    case scheduleArm(session: Int)
    case cancelArm
    case scheduleTapWindow(session: Int)
    case cancelTapWindow
    case startCapture(session: Int)
    case stopCapture(session: Int)
    case abortCapture
    /// Show the raw transcript dimmed while the LLM is asked about it.
    case showRefining(text: String)
    case refine(session: Int, text: String)
    case cancelRefine
    case inject(session: Int, text: String)
    /// Swap the typed raw text for `text` where it was typed, if it is still there untouched.
    case replace(session: Int, text: String)
    /// The dictation's text is where it will stay (typed, swapped, or abandoned as typed): finish
    /// its bookkeeping. Emitted once per dictation that typed something; never for one that was
    /// cancelled, failed, or heard nothing.
    case settle(session: Int)
    case hideCapsule
    /// Show a short message in the capsule, then hide it.
    case notify(String)
}

/// Pure reducer for the dictation lifecycle. Every async result carries the session id it was
/// started for, so a late result from a cancelled session can never leak into a newer one.
///
/// Everything a phase needs to know travels in its payload (`State`), so there is no flag to reset
/// between dictations and no combination of flags that the phase doesn't account for.
public struct DictationMachine: Sendable {
    /// How the current recording is being held.
    private enum Hold: Equatable {
        /// Fn is held down; releasing it stops.
        case held
        /// Started by a double tap; the next Fn press stops. `pressHeld` is true while the press
        /// that locked recording is still down, so a combo key then means it was a shortcut.
        case locked(pressHeld: Bool)
    }

    /// What happens once the current paste lands.
    private enum AfterInject: Equatable {
        /// The dictation ends.
        case finish
        /// The LLM is answering about the typed text; `pending` is an answer that arrived already.
        case swap(pending: String?)
    }

    private enum State: Equatable {
        case idle
        case arming
        case tapped
        case recording(Hold)
        case finalizing
        case refining
        case injecting(AfterInject)
        case refiningInPlace
        case replacing
    }

    private var state: State = .idle
    public private(set) var session = 0

    public var phase: DictationPhase {
        switch state {
        case .idle: .idle
        case .arming: .arming
        case .tapped: .tapped
        case .recording: .recording
        case .finalizing: .finalizing
        case .refining: .refining
        case .injecting: .injecting
        case .refiningInPlace: .refiningInPlace
        case .replacing: .replacing
        }
    }

    /// Recording started by a double tap: Fn-up doesn't stop it, the next Fn press does.
    public var locked: Bool {
        if case .recording(.locked) = state { return true }
        return false
    }

    /// How long after a quick Fn tap a second press still counts as a double tap.
    public static let tapWindow: Duration = .milliseconds(350)

    public init() {}

    public mutating func send(_ event: DictationEvent) -> [DictationEffect] {
        switch (state, event) {
        case (.idle, .fnDown):
            session += 1
            state = .arming
            return [.scheduleArm(session: session)]

        case (.arming, .fnUp):
            state = .tapped
            return [.cancelArm, .scheduleTapWindow(session: session)]

        case (.arming, .comboKey), (.arming, .cancel):
            state = .idle
            return [.cancelArm]

        case (.arming, .armElapsed(let s)) where s == session:
            state = .recording(.held)
            return [.startCapture(session: s)]

        case (.tapped, .fnDown):
            session += 1
            state = .recording(.locked(pressHeld: true))
            return [.cancelTapWindow, .startCapture(session: session)]

        case (.tapped, .tapWindowElapsed(let s)) where s == session:
            state = .idle
            return []

        case (.tapped, .cancel), (.tapped, .comboKey):
            state = .idle
            return [.cancelTapWindow]

        case (.recording(.locked), .fnUp):
            state = .recording(.locked(pressHeld: false))
            return []

        case (.recording(.locked), .fnDown), (.recording(.held), .fnUp):
            state = .finalizing
            return [.stopCapture(session: session)]

        case (.recording(.locked(pressHeld: true)), .comboKey):
            state = .idle
            return [.abortCapture, .hideCapsule]

        case (.recording, .finish(let s)) where s == session:
            state = .finalizing
            return [.stopCapture(session: s)]

        case (.recording, .cancel), (.finalizing, .cancel):
            state = .idle
            return [.abortCapture, .hideCapsule]

        case (.recording, .captureFailed(let s, let message)) where s == session:
            state = .idle
            return [.abortCapture, .notify(message)]

        case (.finalizing, .captureFailed(let s, let message)) where s == session:
            state = .idle
            return [.notify(message)]

        case (.finalizing, .transcriptFinal(let s, let text, let plan)) where s == session:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                state = .idle
                return [.hideCapsule]
            }
            switch plan {
            case .none:
                state = .injecting(.finish)
                return [.inject(session: s, text: trimmed)]
            case .beforeTyping:
                state = .refining
                return [.showRefining(text: trimmed), .refine(session: s, text: trimmed)]
            case .afterTyping:
                state = .injecting(.swap(pending: nil))
                return [.refine(session: s, text: trimmed), .inject(session: s, text: trimmed)]
            }

        case (.refining, .refined(let s, let text)) where s == session:
            state = .injecting(.finish)
            return [.inject(session: s, text: text)]

        case (.refining, .cancel):
            state = .idle
            return [.cancelRefine, .hideCapsule]

        case (.injecting(.swap), .refined(let s, let text)) where s == session:
            state = .injecting(.swap(pending: text))
            return []

        case (.injecting(let after), .injected(let s, let notice, let typed)) where s == session:
            let shown: DictationEffect = notice.map { .notify($0) } ?? .hideCapsule
            switch after {
            case .finish:
                state = .idle
                return [shown, .settle(session: s)]
            case .swap where !typed:
                // Nothing went out, so there is nothing to swap; the answer would be wasted.
                state = .idle
                return [.cancelRefine, shown, .settle(session: s)]
            case .swap(let pending?):
                state = .replacing
                return [shown, .replace(session: s, text: pending)]
            case .swap:
                state = .refiningInPlace
                return [shown]
            }

        case (.refiningInPlace, .refined(let s, let text)) where s == session:
            state = .replacing
            return [.replace(session: s, text: text)]

        case (.refiningInPlace, .fnDown):
            // The user moved on: the typed text stays as it is and a new dictation starts.
            let abandoned = session
            session += 1
            state = .arming
            return [.cancelRefine, .settle(session: abandoned), .scheduleArm(session: session)]

        case (.replacing, .replaced(let s, let notice)) where s == session:
            state = .idle
            if let notice { return [.notify(notice), .settle(session: s)] }
            return [.settle(session: s)]

        default:
            // Includes Fn-down while refining/injecting/replacing (ignored by design) and stale session results.
            return []
        }
    }
}
