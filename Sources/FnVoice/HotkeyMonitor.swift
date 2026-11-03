import AppKit
import FnVoiceCore

/// Global CGEvent tap for Fn (and Esc while dictating). The tap callback runs on the main run
/// loop and must return fast — a slow callback gets the tap disabled by the system — so it only
/// classifies the event and defers any work.
@MainActor final class HotkeyMonitor {
    var onAction: ((KeyAction) -> Void)?
    var isCancellable: () -> Bool = { false }

    private var tracker = FnKeyTracker()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var loggedInstallFailure = false

    var isInstalled: Bool { tap != nil }

    /// Fails (returns false) until Accessibility is granted.
    func install() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !loggedInstallFailure {
                loggedInstallFailure = true
                Log.hotkey.notice("event tap creation failed (Accessibility not granted?); retrying quietly")
            }
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.hotkey.info("event tap installed")
        return true
    }

    /// Returns true to swallow the event. `input` is nil for tap-disabled notifications.
    fileprivate func process(type: CGEventType, input: KeyEventInput?) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.hotkey.notice("event tap disabled by system (\(type.rawValue, privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            tracker.reset()
            // We may have missed Fn-up while disabled; treat it as released.
            emit(.fnUp)
            return false
        }
        guard let input else { return false }
        let (disposition, action) = tracker.handle(input, dictationCancellable: isCancellable())
        if let action { emit(action) }
        return disposition == .suppress
    }

    nonisolated fileprivate static func input(type: CGEventType, event: CGEvent) -> KeyEventInput? {
        let kind: KeyEventInput.Kind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return nil
        }
        let flags = event.flags
        return KeyEventInput(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            fnFlag: flags.contains(.maskSecondaryFn),
            otherModifiers: !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        )
    }

    private func emit(_ action: KeyAction) {
        Task { @MainActor in self.onAction?(action) }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let input = HotkeyMonitor.input(type: type, event: event)
    let swallow = MainActor.assumeIsolated { monitor.process(type: type, input: input) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
