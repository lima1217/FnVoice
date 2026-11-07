import Foundation

/// A keyboard event reduced to the fields the tracker needs, so the decision logic can be
/// tested without constructing CGEvents.
public struct KeyEventInput: Equatable, Sendable {
    public enum Kind: Sendable { case flagsChanged, keyDown, keyUp }

    public var kind: Kind
    public var keyCode: UInt16
    /// Whether the secondary-Fn flag is set on this event.
    public var fnFlag: Bool
    /// Whether Command, Control, Option or Shift is held.
    public var otherModifiers: Bool

    public init(kind: Kind, keyCode: UInt16, fnFlag: Bool, otherModifiers: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.fnFlag = fnFlag
        self.otherModifiers = otherModifiers
    }
}

public enum KeyDisposition: Equatable, Sendable { case passThrough, suppress }
public enum KeyAction: Equatable, Sendable { case fnDown, fnUp, comboKey, escape }

/// Decides, per event, whether the event tap should swallow it and what it means for dictation.
///
/// Rules:
/// - Only a *bare* Fn press (no Cmd/Ctrl/Opt/Shift held) is claimed for dictation. Its
///   flagsChanged down/up events are suppressed so the system doesn't open the emoji picker.
/// - Arrow keys and F-keys carry the Fn flag on their own, so Fn is detected by keyCode on
///   flagsChanged, never by the flag on keyDown.
/// - Any other key pressed while a claimed Fn is held is passed through untouched and reported
///   as a combo, which aborts dictation while still arming.
/// - Esc is swallowed only while a dictation can be cancelled.
public struct FnKeyTracker: Sendable {
    public static let fnKeyCode: UInt16 = 63
    /// Some Apple keyboards report the Globe key under this code.
    public static let globeKeyCode: UInt16 = 179
    public static let escapeKeyCode: UInt16 = 53

    /// The Fn key as the tracker last saw it. A held press is either claimed for dictation (a
    /// bare press) or left to the system (a press with another modifier down).
    private enum Fn: Equatable {
        case released
        case held(claimed: Bool)
    }

    private var fn: Fn = .released
    /// An Esc key-down was swallowed; its key-up must be too, whatever dictation does meanwhile.
    private var escapeSuppressed = false

    public var fnHeld: Bool { fn != .released }
    private var claimed: Bool { fn == .held(claimed: true) }

    public init() {}

    private static func isFnKey(_ code: UInt16) -> Bool {
        code == fnKeyCode || code == globeKeyCode
    }

    public mutating func handle(_ e: KeyEventInput, dictationCancellable: Bool) -> (KeyDisposition, KeyAction?) {
        switch e.kind {
        case .flagsChanged:
            if Self.isFnKey(e.keyCode) {
                switch (fn, e.fnFlag) {
                case (.released, true):
                    let claimed = !e.otherModifiers
                    fn = .held(claimed: claimed)
                    return claimed ? (.suppress, .fnDown) : (.passThrough, nil)
                case (.held(let claimed), false):
                    fn = .released
                    return claimed ? (.suppress, .fnUp) : (.passThrough, nil)
                case (.held(let claimed), true):
                    return (claimed ? .suppress : .passThrough, nil)
                case (.released, false):
                    return (.passThrough, nil)
                }
            }
            // A modifier other than Fn changed while Fn is claimed: treat as a combo (e.g. Fn+Shift).
            if claimed && e.otherModifiers { return (.passThrough, .comboKey) }
            return (.passThrough, nil)

        case .keyDown:
            if e.keyCode == Self.escapeKeyCode && dictationCancellable {
                escapeSuppressed = true
                return (.suppress, .escape)
            }
            if Self.isFnKey(e.keyCode) { return (fnHeld ? .suppress : .passThrough, nil) }
            if claimed { return (.passThrough, .comboKey) }
            return (.passThrough, nil)

        case .keyUp:
            if e.keyCode == Self.escapeKeyCode && escapeSuppressed {
                escapeSuppressed = false
                return (.suppress, nil)
            }
            if Self.isFnKey(e.keyCode) { return (fnHeld ? .suppress : .passThrough, nil) }
            return (.passThrough, nil)
        }
    }

    /// Called when the tap was re-enabled after the system disabled it (the main thread was busy
    /// too long, e.g. an Accessibility call into a hung app). Events may have been missed, so sync
    /// with the key as it physically is: if Fn is still down, the user is still dictating and
    /// nothing changes; if it was released meanwhile, report the Fn-up that was missed.
    public mutating func resync(fnPhysicallyDown: Bool) -> KeyAction? {
        escapeSuppressed = false
        guard !fnPhysicallyDown else { return nil }
        let wasClaimed = claimed
        fn = .released
        return wasClaimed ? .fnUp : nil
    }
}
