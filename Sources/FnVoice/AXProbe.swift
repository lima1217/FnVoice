import AppKit
import ApplicationServices

/// `--ax-probe`: what the in-place swap would see in another app's focused field. Runs the same
/// `EditWatcher` calls `InPlaceReplacer` makes, so "it skipped in app X" can be reproduced
/// without dictating. Selects up to 3 characters before the caret, then puts the caret back.
///   --pid N | --app Name   target (default: the frontmost app after --delay)
///   --delay S              seconds to wait first, to click into the field (default 0)
@MainActor enum AXProbe {
    static func run(arguments args: [String]) async -> Int32 {
        let delay = argumentValue("--delay", in: args).flatMap(Double.init) ?? 0
        try? await Task.sleep(for: .seconds(delay))

        let target: NSRunningApplication?
        if let pid = argumentValue("--pid", in: args).flatMap(Int32.init) {
            target = NSRunningApplication(processIdentifier: pid)
        } else if let name = argumentValue("--app", in: args) {
            target = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
        } else {
            target = NSWorkspace.shared.frontmostApplication
        }
        print("accessibility trusted: \(AXIsProcessTrusted())")
        guard let app = target else { print("FAIL no such app"); return 1 }
        print("target: \(app.localizedName ?? "?") \(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier)")

        let clock = ContinuousClock()
        func focused(within limit: Duration) async -> AXUIElement? {
            let deadline = clock.now + limit
            while clock.now < deadline {
                if let element = EditWatcher.focusedElement(pid: app.processIdentifier) { return element }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return nil
        }
        var element = await focused(within: .seconds(1))
        if element == nil {
            // Chromium and Electron keep their AX tree off until an assistive client asks for it.
            // FnVoice never asks, so in such a window it waits for the LLM instead of typing first.
            print("note: no focused element as FnVoice sees it; turning on the app's AX tree to test selection")
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            element = await focused(within: .seconds(3))
        }
        guard let element else { print("FAIL no focused element (or a secure field)"); return 1 }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let value = EditWatcher.value(of: element)
        print("role: \(role as? String ?? "?")")
        print("readable (swap path chosen at Fn-down): \(value != nil)", value.map { "length=\(($0 as NSString).length)" } ?? "")
        guard let caret = EditWatcher.selectedRange(of: element) else { print("FAIL no selected-text range"); return 1 }
        print("selection before: \(caret)")
        guard caret.length == 0, caret.location > 0 else {
            print("SKIP need a plain caret after some text to test selection")
            return 0
        }

        let want = NSRange(location: max(0, caret.location - 3), length: min(3, caret.location))
        let start = clock.now
        let selected = await EditWatcher.select(want, in: element)
        print("select \(want): \(selected ? "accepted" : "NOT accepted") after \(ms(clock.now - start))")
        let restored = await EditWatcher.select(NSRange(location: caret.location, length: 0), in: element)
        print("caret restored: \(restored)")
        print(selected && value != nil ? "PASS swap would work here" : "FAIL swap would skip here")
        return selected && value != nil ? 0 : 1
    }

    private static func ms(_ d: Duration) -> String {
        "\(Int(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000))ms"
    }
}
