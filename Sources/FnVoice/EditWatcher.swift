import AppKit
import ApplicationServices
import FnVoiceCore

/// After a paste, watches the focused text field through Accessibility to see how the user fixes
/// the dictated text, and reports the corrections.
///
/// The field is polled until it loses focus, the user leaves the app, the pasted span can no longer
/// be located (e.g. Enter sent and cleared a chat box), the next dictation starts, or a time limit.
/// The last *stable* reading wins (unchanged across two polls), so half-typed pinyin in an IME
/// composition is never taken for the user's fix. Field contents stay in memory only.
@MainActor final class EditWatcher {
    private static let poll: Duration = .milliseconds(400)
    private static let maxWatch: Duration = .seconds(180)
    /// Huge documents are slow to read over AX on every poll; skip them.
    private static let maxFieldLength = 20_000

    private var task: Task<Void, Never>?
    private var finish: (() -> Void)?

    /// Starts watching; any watch already running is finalized first. `onSettled` always runs once,
    /// with the pasted span as the user left it, or nil if the field couldn't be read.
    func watch(
        pasted: String, pid: Int32, onCorrections: @escaping ([Correction]) -> Void,
        onSettled: ((String?) -> Void)? = nil
    ) {
        stop()
        guard !pasted.isEmpty else {
            onSettled?(nil)
            return
        }
        var stable: String?
        var lastSeen: String?
        var done = false
        let finalize = {
            guard !done else { return }
            done = true
            onSettled?(stable)
            guard let edited = stable, edited != pasted else { return }
            let found = CorrectionExtractor.extract(pasted: pasted, edited: edited)
            if !found.isEmpty { onCorrections(found) }
        }
        finish = finalize
        task = Task { @MainActor [weak self] in
            defer { finalize(); self?.finish = nil }
            guard let baseline = await Self.locate(pasted: pasted, pid: pid) else {
                Log.app.debug("edit watch: pasted text not readable in focused field")
                return
            }
            stable = pasted
            let clock = ContinuousClock()
            let deadline = clock.now + Self.maxWatch
            while clock.now < deadline {
                try? await Task.sleep(for: Self.poll)
                if Task.isCancelled { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let element = Self.focusedElement(pid: pid), CFEqual(element, baseline.element),
                      let value = Self.value(of: element),
                      let edited = EditRegion.edited(before: baseline.value, after: value, range: baseline.range)
                else { return }
                if edited == lastSeen { stable = edited }
                lastSeen = edited
            }
        }
    }

    /// Finalizes the current watch with what it has seen so far.
    func stop() {
        task?.cancel()
        task = nil
        finish?()
        finish = nil
    }

    // MARK: - Accessibility

    /// One Accessibility read of the focused field of `pid`: whether it can be read back, which is
    /// what a later in-place replacement needs (password fields and huge documents can't), and the
    /// text before the caret (before the selection, if any), nil when the caret can't be read.
    static func readFocusedField(pid: Int32) -> (readable: Bool, before: String?) {
        guard let element = focusedElement(pid: pid), let value = value(of: element) else { return (false, nil) }
        guard let selection = selectedRange(of: element) else { return (true, nil) }
        let ns = value as NSString
        let end = min(max(selection.location, 0), ns.length)
        guard end > 0 else { return (true, "") }
        // A tail generously longer than RefinementContext keeps, cut on a character boundary.
        let start = ns.rangeOfComposedCharacterSequence(at: max(0, end - RefinementContext.maxBefore * 4)).location
        return (true, ns.substring(with: NSRange(location: start, length: end - start)))
    }

    private struct Baseline {
        var element: AXUIElement
        var value: String
        var range: Range<Int>
    }

    /// The target applies ⌘V asynchronously; retry briefly until the pasted text shows up.
    private static func locate(pasted: String, pid: Int32) async -> Baseline? {
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(150))
            guard let element = focusedElement(pid: pid), let value = value(of: element) else { continue }
            if let range = pastedRange(pasted, in: value, caret: caret(of: element)) {
                return Baseline(element: element, value: value, range: range)
            }
        }
        return nil
    }

    /// Prefers the occurrence ending at the caret (where ⌘V leaves it), else the last one.
    static func pastedRange(_ pasted: String, in value: String, caret: Int?) -> Range<Int>? {
        let ns = value as NSString
        var found: NSRange?
        if let caret, caret >= (pasted as NSString).length {
            let r = NSRange(location: caret - (pasted as NSString).length, length: (pasted as NSString).length)
            if r.upperBound <= ns.length, ns.substring(with: r) == pasted { found = r }
        }
        if found == nil {
            let r = ns.range(of: pasted, options: .backwards)
            if r.location != NSNotFound { found = r }
        }
        guard let found, let lower = Range(NSRange(location: 0, length: found.location), in: value),
              let span = Range(found, in: value) else { return nil }
        let start = value[lower].count
        return start..<(start + value[span].count)
    }

    static func focusedElement(pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        return element
    }

    static func value(of element: AXUIElement) -> String? {
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(element, kAXValueAttribute as CFString, &count) == .success,
           count > maxFieldLength { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
              let s = ref as? String, (s as NSString).length <= maxFieldLength else { return nil }
        return s
    }

    /// Caret position in UTF-16 units.
    static func caret(of element: AXUIElement) -> Int? {
        selectedRange(of: element).map { $0.location + $0.length }
    }

    /// The selection in UTF-16 units; length 0 is a plain caret.
    static func selectedRange(of element: AXUIElement) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Asks the field to select `range`, and reports whether it did (some apps accept the call and ignore it).
    /// Chromium and Electron fields (Chrome, the Claude and Slack apps…) apply the range
    /// asynchronously: the set returns success, an immediate read still gives the old caret, and the
    /// new range shows 10–40 ms later (measured 2026-11-07). Reading back at once made every swap in
    /// those apps skip as "selection not accepted", so wait up to `settle` for the range to land.
    static func select(_ range: NSRange, in element: AXUIElement, settle: Duration = .milliseconds(200)) async -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now + settle
        while selectedRange(of: element) != range {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
