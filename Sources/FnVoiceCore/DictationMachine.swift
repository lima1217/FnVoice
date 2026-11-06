import Foundation

/// Lifecycle of one dictation. `arming` is the 150ms window between Fn-down and the
/// moment we commit to recording, so a quick Fn tap or an Fn+key combo never starts the mic.
///
/// Double-tapping Fn locks recording for long dictation: a quick tap opens `tapped` for
/// `DictationMachine.tapWindow`, and pressing Fn again inside it starts recording at once, with
/// `locked` set. Releasing Fn then keeps recording; the next Fn press finishes, Esc cancels.
public enum DictationPhase: Equatable, Sendable {
    case idle, arming, recording, finalizing, refining, injecting
    /// Fn was tapped; another press within the tap window locks recording.
    case tapped

    /// Esc can abort these phases. Once injection has begun it is too late to take the text back.
    public var isCancellable: Bool {
        switch self {
        case .arming, .recording, .finalizing, .refining: true
        case .idle, .injecting, .tapped: false
        }
    }
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
    case transcriptFinal(session: Int, text: String, refine: Bool)
    case refined(session: Int, text: String)
    case injected(session: Int, notice: String?)
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
    case refine(session: Int, text: String)
    case cancelRefine
    case inject(session: Int, text: String)
    case hideCapsule
    /// Show a short message in the capsule, then hide it.
    case notify(String)
}

/// Pure reducer for the dictation lifecycle. Every async result carries the session id it was
/// started for, so a late result from a cancelled session can never leak into a newer one.
public struct DictationMachine: Sendable {
    public private(set) var phase: DictationPhase = .idle
    public private(set) var session = 0
    /// Recording started by a double tap: Fn-up doesn't stop it, the next Fn press does.
    public private(set) var locked = false
    /// The press that locked recording is still held, so a combo key means it was a shortcut.
    private var lockingPressHeld = false

    /// How long after a quick Fn tap a second press still counts as a double tap.
    public static let tapWindow: Duration = .milliseconds(350)

    public init() {}

    public mutating func send(_ event: DictationEvent) -> [DictationEffect] {
        switch (phase, event) {
        case (.idle, .fnDown):
            session += 1
            phase = .arming
            return [.scheduleArm(session: session)]

        case (.arming, .fnUp):
            phase = .tapped
            return [.cancelArm, .scheduleTapWindow(session: session)]

        case (.arming, .comboKey), (.arming, .cancel):
            phase = .idle
            return [.cancelArm]

        case (.tapped, .fnDown):
            session += 1
            phase = .recording
            locked = true
            lockingPressHeld = true
            return [.cancelTapWindow, .startCapture(session: session)]

        case (.tapped, .tapWindowElapsed(let s)) where s == session:
            phase = .idle
            return []

        case (.tapped, .cancel), (.tapped, .comboKey):
            phase = .idle
            return [.cancelTapWindow]

        case (.recording, .fnUp) where locked:
            lockingPressHeld = false
            return []

        case (.recording, .fnDown) where locked:
            locked = false
            phase = .finalizing
            return [.stopCapture(session: session)]

        case (.recording, .comboKey) where locked && lockingPressHeld:
            locked = false
            lockingPressHeld = false
            phase = .idle
            return [.abortCapture, .hideCapsule]

        case (.recording, .finish(let s)) where s == session:
            locked = false
            lockingPressHeld = false
            phase = .finalizing
            return [.stopCapture(session: s)]

        case (.arming, .armElapsed(let s)) where s == session:
            phase = .recording
            return [.startCapture(session: s)]

        case (.recording, .fnUp):
            phase = .finalizing
            return [.stopCapture(session: session)]

        case (.recording, .cancel), (.finalizing, .cancel):
            locked = false
            lockingPressHeld = false
            phase = .idle
            return [.abortCapture, .hideCapsule]

        case (.recording, .captureFailed(let s, let message)) where s == session:
            locked = false
            lockingPressHeld = false
            phase = .idle
            return [.abortCapture, .notify(message)]

        case (.finalizing, .captureFailed(let s, let message)) where s == session:
            phase = .idle
            return [.notify(message)]

        case (.finalizing, .transcriptFinal(let s, let text, let refine)) where s == session:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                phase = .idle
                return [.hideCapsule]
            }
            if refine {
                phase = .refining
                return [.refine(session: s, text: trimmed)]
            }
            phase = .injecting
            return [.inject(session: s, text: trimmed)]

        case (.refining, .refined(let s, let text)) where s == session:
            phase = .injecting
            return [.inject(session: s, text: text)]

        case (.refining, .cancel):
            phase = .idle
            return [.cancelRefine, .hideCapsule]

        case (.injecting, .injected(let s, let notice)) where s == session:
            phase = .idle
            if let notice { return [.notify(notice)] }
            return [.hideCapsule]

        default:
            // Includes Fn-down while refining/injecting (ignored by design) and stale session results.
            return []
        }
    }
}
