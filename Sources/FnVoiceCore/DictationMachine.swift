import Foundation

/// Lifecycle of one dictation. `arming` is the 150ms window between Fn-down and the
/// moment we commit to recording, so a quick Fn tap or an Fn+key combo never starts the mic.
public enum DictationPhase: Equatable, Sendable {
    case idle, arming, recording, finalizing, refining, injecting

    /// Esc can abort these phases. Once injection has begun it is too late to take the text back.
    public var isCancellable: Bool {
        switch self {
        case .arming, .recording, .finalizing, .refining: true
        case .idle, .injecting: false
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
    case transcriptFinal(session: Int, text: String, refine: Bool)
    case refined(session: Int, text: String)
    case injected(session: Int, notice: String?)
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
    case hideCapsule
    /// Show a short message in the capsule, then hide it.
    case notify(String)
}

/// Pure reducer for the dictation lifecycle. Every async result carries the session id it was
/// started for, so a late result from a cancelled session can never leak into a newer one.
public struct DictationMachine: Sendable {
    public private(set) var phase: DictationPhase = .idle
    public private(set) var session = 0

    public init() {}

    public mutating func send(_ event: DictationEvent) -> [DictationEffect] {
        switch (phase, event) {
        case (.idle, .fnDown):
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
