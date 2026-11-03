import AppKit

/// End-to-end injection target: one focused NSTextView that mirrors its contents to `--out <file>`.
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private let outPath: String?

    init(outPath: String?) {
        self.outPath = outPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit routes ⌘V to paste: via the Edit menu's key equivalent; without it, paste does nothing.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit InjectProbe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(appItem)
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "InjectProbe"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = window.contentLayoutRect
        scroll.autoresizingMask = [.width, .height]
        textView = scroll.documentView as? NSTextView
        textView.delegate = self
        textView.font = .systemFont(ofSize: 15)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate()
    }

    func textDidChange(_ notification: Notification) {
        guard let outPath else { return }
        try? textView.string.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    let out = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let app = NSApplication.shared
    let delegate = ProbeDelegate(outPath: out)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
