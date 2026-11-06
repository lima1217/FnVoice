import Foundation

/// Lifecycle of one dictation. `arming` is the 150ms window between Fn-down and the
/// moment we commit to recording, so a quick Fn tap or an Fn+key combo never starts the mic.
///
/// Two ways through refinement:
/// - `refining` → `injecting`: wait for the LLM, then type its answer (used when the target field
///   can't be read back through Accessibility, so a later swap would be impossible).
/// - `injecting` → `refiningInPlace` → `replacing`: type the raw text at once, and when the LLM
///   answers something different, swap it in place. The user never waits for the network.
public enum DictationPhase: Equatable, Sendable {
    case idle, arming, recording, finalizing, refining, injecting
    /// The raw text is already typed; the LLM is still answering.
    case refiningInPlace
    /// The LLM's answer is being swapped in for the typed raw text.
    case replacing

    /// Esc can abort these phases. Once text has gone out it is too late to take it back, and
    /// claiming Esc then would steal it from the app the user is already back in.
    public var isCancellable: Bool {
        switch self {
        case .arming, .recording, .finalizing, .refining: true
        case .idle, .injecting, .refiningInPlace, .replacing: false
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
    case startCapture(session: Int)
    case stopCapture(session: Int)
    case abortCapture
    case refine(session: Int, text: String)
    case cancelRefine
    case inject(session: Int, text: String)
    /// Swap the typed raw text for `text` where it was typed, if it is still there untouched.
    case replace(session: Int, text: String)
    case hideCapsule
    /// Show a short message in the capsule, then hide it.
    case notify(String)
}

/// Pure reducer for the dictation lifecycle. Every async result carries the session id it was
/// started for, so a late result from a cancelled session can never leak into a newer one.
public struct DictationMachine: Sendable {
    public private(set) var phase: DictationPhase = .idle
    public private(set) var session = 0
    /// Set while the current dictation types first and refines after.
    private var inPlace = false
    /// An LLM answer that arrived while the raw text was still being typed.
    private var pendingRefined: String?

    public init() {}

    private mutating func reset() {
        inPlace = false
        pendingRefined = nil
    }

    public mutating func send(_ event: DictationEvent) -> [DictationEffect] {
        switch (phase, event) {
        case (.idle, .fnDown):
            reset()
            session += 1
            phase = .arming
            return [.scheduleArm(session: session)]

        case (.arming, .fnUp), (.arming, .comboKey), (.arming, .cancel):
            phase = .idle
            return [.cancelArm]

        case (.arming, .armElapsed(let s)) where s == session:
            phase = .recording
            return [.startCapture(session: s)]

        case (.recording, .fnUp):
            phase = .finalizing
            return [.stopCapture(session: session)]

        case (.recording, .cancel), (.finalizing, .cancel):
            phase = .idle
            return [.abortCapture, .hideCapsule]

        case (.recording, .captureFailed(let s, let message)) where s == session:
            phase = .idle
            return [.abortCapture, .notify(message)]

        case (.finalizing, .captureFailed(let s, let message)) where s == session:
            phase = .idle
            return [.notify(message)]

        case (.finalizing, .transcriptFinal(let s, let text, let plan)) where s == session:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                phase = .idle
                return [.hideCapsule]
            }
            switch plan {
            case .none:
                phase = .injecting
                return [.inject(session: s, text: trimmed)]
            case .beforeTyping:
                phase = .refining
                return [.refine(session: s, text: trimmed)]
            case .afterTyping:
                inPlace = true
                phase = .injecting
                return [.refine(session: s, text: trimmed), .inject(session: s, text: trimmed)]
            }

        case (.refining, .refined(let s, let text)) where s == session:
            phase = .injecting
            return [.inject(session: s, text: text)]

        case (.refining, .cancel):
            phase = .idle
            return [.cancelRefine, .hideCapsule]

        case (.injecting, .refined(let s, let text)) where s == session && inPlace:
            pendingRefined = text
            return []

        case (.injecting, .injected(let s, let notice, let typed)) where s == session:
            let shown: DictationEffect = notice.map { .notify($0) } ?? .hideCapsule
            guard inPlace else {
                phase = .idle
                return [shown]
            }
            guard typed else {
                // Nothing went out, so there is nothing to swap; the answer would be wasted.
                phase = .idle
                reset()
                return [.cancelRefine, shown]
            }
            if let pending = pendingRefined {
                pendingRefined = nil
                phase = .replacing
                return [shown, .replace(session: s, text: pending)]
            }
            phase = .refiningInPlace
            return [shown]

        case (.refiningInPlace, .refined(let s, let text)) where s == session:
            phase = .replacing
            return [.replace(session: s, text: text)]

        case (.refiningInPlace, .fnDown):
            // The user moved on: the typed text stays as it is and a new dictation starts.
            reset()
            session += 1
            phase = .arming
            return [.cancelRefine, .scheduleArm(session: session)]

        case (.replacing, .replaced(let s, let notice)) where s == session:
            phase = .idle
            reset()
            if let notice { return [.notify(notice)] }
            return []

        default:
            // Includes Fn-down while refining/injecting/replacing (ignored by design) and stale session results.
            return []
        }
    }
}
