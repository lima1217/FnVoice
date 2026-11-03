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

    public private(set) var fnHeld = false
    private var claimed = false
    private var escapeSuppressed = false

    public init() {}

    private static func isFnKey(_ code: UInt16) -> Bool {
        code == fnKeyCode || code == globeKeyCode
    }

    public mutating func handle(_ e: KeyEventInput, dictationCancellable: Bool) -> (KeyDisposition, KeyAction?) {
        switch e.kind {
        case .flagsChanged:
            if Self.isFnKey(e.keyCode) {
                if e.fnFlag && !fnHeld {
                    fnHeld = true
                    claimed = !e.otherModifiers
                    return claimed ? (.suppress, .fnDown) : (.passThrough, nil)
                }
                if !e.fnFlag && fnHeld {
                    fnHeld = false
                    if claimed {
                        claimed = false
                        return (.suppress, .fnUp)
                    }
                    return (.passThrough, nil)
                }
                return (claimed ? .suppress : .passThrough, nil)
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
            if Self.isFnKey(e.keyCode) { return (fnHeld || claimed ? .suppress : .passThrough, nil) }
            return (.passThrough, nil)
        }
    }

    /// Called when the tap was re-enabled after the system disabled it: we may have missed
    /// the Fn-up, so start clean.
    public mutating func reset() {
        fnHeld = false
        claimed = false
        escapeSuppressed = false
    }
}
