import AppKit
import ApplicationServices
import FnVoiceCore

/// Swaps the raw text typed at Fn-up for the LLM's answer once it arrives, provided the field
/// still ends with that raw text at the caret. Anything else (the user typed on, pressed Enter in
/// a chat box, moved to another app, the field can't be read or won't take a selection) leaves
/// the raw text alone: a wrong swap is far worse than a missed one.
@MainActor enum InPlaceReplacer {
    enum Outcome: Equatable {
        case replaced
        /// The field moved on; nothing was touched.
        case skipped(String)
        /// Injection itself failed; the caret was put back where it was.
        case failed(String)
    }

    /// `onPasted` runs the moment the answer appears in the field, before the injector's housekeeping.
    static func replace(
        _ typed: String, with text: String, pid: Int32, injector: TextInjector, onPasted: () -> Void = {}
    ) async -> Outcome {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .skipped("app changed") }
        guard let element = EditWatcher.focusedElement(pid: pid), let value = EditWatcher.value(of: element) else {
            return .skipped("field not readable")
        }
        guard let selection = EditWatcher.selectedRange(of: element), selection.length == 0 else {
            return .skipped("text selected")
        }
        let caret = selection.location
        let length = (typed as NSString).length
        guard caret >= length, caret <= (value as NSString).length,
              (value as NSString).substring(with: NSRange(location: caret - length, length: length)) == typed
        else { return .skipped("text moved") }

        let target = NSRange(location: caret - length, length: length)
        guard EditWatcher.select(target, in: element) else {
            // Put the caret back in case the app moved it while refusing the range.
            _ = EditWatcher.select(NSRange(location: caret, length: 0), in: element)
            return .skipped("selection not accepted")
        }
        do {
            _ = try await injector.inject(text, expectedPID: pid, onPasted: onPasted)
            return .replaced
        } catch {
            // The raw text is still selected; a keystroke now would delete it. Deselect first.
            _ = EditWatcher.select(NSRange(location: caret, length: 0), in: element)
            let message = (error as? InjectionError)?.userMessage ?? error.localizedDescription
            return .failed(message)
        }
    }
}
