import AppKit
import FnVoiceCore
import QuartzCore

/// Frameless, non-activating capsule at the bottom of the active screen.
@MainActor final class CapsulePanel {
    enum Metrics {
        static let height: CGFloat = 56
        static let radius: CGFloat = 28
        static let leftPadding: CGFloat = 16
        static let waveSize = NSSize(width: 44, height: 32)
        static let gap: CGFloat = 12
        static let rightPadding: CGFloat = 22
        static let minLabel: CGFloat = 160
        static let maxLabel: CGFloat = 560
        static let bottomMargin: CGFloat = 36
    }

    private let panel: NSPanel
    private let effect: NSVisualEffectView
    private let waveform: WaveformView
    private let label: NSTextField
    private var screen: NSScreen?
    private var visible = false
    private var hideWork: Task<Void, Never>?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: Metrics.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .vibrantDark)

        let root = NSView(frame: panel.contentLayoutRect)
        root.wantsLayer = true
        panel.contentView = root

        effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.capsuleMask(radius: Metrics.radius)
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        root.addSubview(effect)

        waveform = WaveformView(frame: NSRect(
            x: Metrics.leftPadding, y: (Metrics.height - Metrics.waveSize.height) / 2,
            width: Metrics.waveSize.width, height: Metrics.waveSize.height
        ))
        effect.addSubview(waveform)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingHead // newest words stay visible
        label.cell?.truncatesLastVisibleLine = true
        label.autoresizingMask = [.width]
        effect.addSubview(label)
    }

    // MARK: - Public

    /// `locked`: recording continues after Fn is released (double-tap), so say how to finish.
    func show(levels: LevelBox, locked: Bool = false) {
        hideWork?.cancel()
        hideWork = nil
        screen = ScreenLocator.activeScreen()
        waveform.start(levels: levels, jitter: !reduceMotion)
        setPlaceholder(locked ? "🔒 Listening · Fn to finish" : "Listening…")
        let frame = frameFor(labelWidth: Metrics.minLabel)
        // Size the window first: the label autoresizes with it, so lay it out afterwards.
        panel.setFrame(frame, display: true)
        layoutLabel(width: Metrics.minLabel)
        if visible { return }
        visible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        effect.layer?.removeAllAnimations()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.2 : 0.18
            panel.animator().alphaValue = 1
        }
        guard !reduceMotion, let layer = effect.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: centeredScale(0.7, in: frame.size))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 300
        spring.damping = 22 // ζ≈0.64: one gentle overshoot, settles in ~0.35s
        spring.duration = 0.35
        layer.add(spring, forKey: "entry")
    }

    func setText(_ text: String) {
        guard visible else { return }
        label.textColor = .white
        label.stringValue = text
        resizeToFitText()
    }

    /// Shows the raw transcript dimmed while the LLM is asked about it, so the user sees what was
    /// heard instead of an empty capsule for a second or two. Only the text's colour tells it apart
    /// from the final text, which arrives white.
    func showRefining(_ transcript: String) {
        guard visible else { return }
        waveform.idle()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        setPlaceholder(text.isEmpty ? "Refining…" : text)
    }

    /// Shows a message briefly, then hides. Works whether or not the capsule is up.
    func flash(_ message: String) {
        if !visible {
            screen = ScreenLocator.activeScreen()
            visible = true
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        waveform.idle()
        label.textColor = NSColor(calibratedRed: 1, green: 0.8, blue: 0.5, alpha: 1)
        label.stringValue = message
        resizeToFitText()
        hideWork?.cancel()
        hideWork = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        guard visible else { return }
        visible = false
        hideWork?.cancel()
        hideWork = nil
        waveform.stop()
        let duration = 0.22
        if !reduceMotion, let layer = effect.layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: centeredScale(0.85, in: panel.frame.size))
            shrink.duration = duration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "exit")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                guard !self.visible else { return } // re-shown mid-animation
                self.panel.orderOut(nil)
                self.effect.layer?.removeAllAnimations()
            }
        })
    }

    // MARK: - Layout

    private func setPlaceholder(_ text: String) {
        label.textColor = NSColor.white.withAlphaComponent(0.55)
        label.stringValue = text
        resizeToFitText()
    }

    private func resizeToFitText() {
        let measured = ceil(label.attributedStringValue.size().width) + 4
        let width = min(max(measured, Metrics.minLabel), Metrics.maxLabel)
        let target = frameFor(labelWidth: width)
        guard abs(target.width - panel.frame.width) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
        panel.invalidateShadow()
    }

    private func layoutLabel(width: CGFloat) {
        let x = Metrics.leftPadding + Metrics.waveSize.width + Metrics.gap
        let h: CGFloat = 20
        label.frame = NSRect(x: x, y: (Metrics.height - h) / 2, width: width, height: h)
    }

    private func frameFor(labelWidth: CGFloat) -> NSRect {
        let width = Metrics.leftPadding + Metrics.waveSize.width + Metrics.gap + labelWidth + Metrics.rightPadding
        let visibleFrame = (screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSRect(
            x: round(visibleFrame.midX - width / 2),
            y: visibleFrame.minY + Metrics.bottomMargin,
            width: width, height: Metrics.height
        )
    }

    /// Layer-backed NSViews anchor at (0,0); scale around the center explicitly.
    private func centeredScale(_ s: CGFloat, in size: NSSize) -> CATransform3D {
        var t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
    }

    private static func capsuleMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Five bars driven by live RMS through `WaveformEnvelope`, redrawn on the display's refresh.
@MainActor final class WaveformView: NSView {
    private var envelope = WaveformEnvelope()
    private var levels: LevelBox?
    private var link: CADisplayLink?
    private var bars: [Float] = Array(repeating: 0, count: 5)

    private let barWidth: CGFloat = 5
    private let minBarHeight: CGFloat = 4

    func start(levels: LevelBox, jitter: Bool) {
        self.levels = levels
        envelope = WaveformEnvelope()
        envelope.jitter = jitter ? 0.04 : 0
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// Stop following the mic (e.g. while refining); bars decay to rest via the release curve.
    func idle() { levels = nil }

    func stop() {
        link?.invalidate()
        link = nil
        levels = nil
    }

    @objc private func tick() {
        envelope.step(target: levels?.get() ?? 0)
        bars = envelope.barLevels()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = CGFloat(bars.count)
        let spacing = (bounds.width - barWidth * count) / (count - 1)
        NSColor.white.withAlphaComponent(0.92).setFill()
        for (i, level) in bars.enumerated() {
            let h = max(minBarHeight, CGFloat(level) * bounds.height)
            let rect = NSRect(x: CGFloat(i) * (barWidth + spacing), y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

enum ScreenLocator {
    /// Screen containing the focused window (via Accessibility), falling back to the mouse's screen.
    @MainActor static func activeScreen() -> NSScreen? {
        if let rect = focusedWindowFrame(),
           let s = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) {
            return s
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    @MainActor private static func focusedWindowFrame() -> NSRect? {
        guard AXIsProcessTrusted(), let primary = NSScreen.screens.first else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1) // never hang on an unresponsive app
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let app = appRef, CFGetTypeID(app) == AXUIElementGetTypeID() else { return nil }
        let appElement = app as! AXUIElement
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        let window = win as! AXUIElement
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        // AX uses top-left origin relative to the primary screen; Cocoa uses bottom-left.
        return NSRect(x: pos.x, y: primary.frame.height - pos.y - size.height, width: size.width, height: size.height)
    }
}
