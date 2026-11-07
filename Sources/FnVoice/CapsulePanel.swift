import AppKit
import FnVoiceCore
import QuartzCore

/// Small frameless, non-activating pill at the bottom of the active screen: a waveform while
/// listening, a slow wave while the LLM is asked before typing, and a line of text only for
/// notices. The dictated text itself goes straight into the field (`LiveTyper`), so the pill
/// never has to grow to show it.
@MainActor final class CapsulePanel {
    enum Metrics {
        static let height: CGFloat = 30
        static let padding: CGFloat = 11
        static let waveSize = NSSize(width: 30, height: 16)
        static let lockSize: CGFloat = 10
        static let lockGap: CGFloat = 6
        static let textPadding: CGFloat = 14
        static let maxLabel: CGFloat = 420
        static let bottomMargin: CGFloat = 28
    }

    private enum Content: Equatable {
        case wave(locked: Bool)
        case message
    }

    private let panel: NSPanel
    private let effect: NSVisualEffectView
    private let border: NSView
    private let waveform: WaveformView
    private let lock: NSImageView
    private let label: NSTextField
    private var screen: NSScreen?
    private var visible = false
    private var content = Content.wave(locked: false)
    private var hideWork: Task<Void, Never>?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: Metrics.height),
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

        let radius = Metrics.height / 2
        effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.capsuleMask(radius: radius)
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        root.addSubview(effect)

        // A hairline edge keeps the dark pill readable on dark backgrounds.
        border = NSView(frame: root.bounds)
        border.wantsLayer = true
        border.layer?.cornerRadius = radius
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        border.autoresizingMask = [.width, .height]
        effect.addSubview(border)

        waveform = WaveformView(frame: NSRect(origin: .zero, size: Metrics.waveSize))
        effect.addSubview(waveform)

        lock = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.lockSize, weight: .semibold)
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?.withSymbolConfiguration(config)
        lock.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        lock.frame = NSRect(x: 0, y: 0, width: Metrics.lockSize + 2, height: Metrics.lockSize + 4)
        effect.addSubview(lock)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        effect.addSubview(label)
    }

    // MARK: - Public

    /// `locked`: recording continues after Fn is released (double-tap); a lock shows beside the wave.
    func show(levels: LevelBox, locked: Bool = false) {
        hideWork?.cancel()
        hideWork = nil
        screen = ScreenLocator.activeScreen()
        waveform.start(levels: levels, jitter: !reduceMotion)
        setContent(.wave(locked: locked), animated: visible)
        if visible { return }
        visible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        effect.layer?.removeAllAnimations()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.2 : 0.16
            panel.animator().alphaValue = 1
        }
        guard !reduceMotion, let layer = effect.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: centeredScale(0.6, in: panel.frame.size))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 20 // one small overshoot, settles in ~0.35 s
        spring.duration = 0.35
        layer.add(spring, forKey: "entry")
    }

    /// The LLM is answering before anything is typed: the bars stop following the mic and roll
    /// as a slow wave instead.
    func showRefining() {
        guard visible else { return }
        waveform.think(animated: !reduceMotion)
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
        label.textColor = NSColor(calibratedRed: 1, green: 0.82, blue: 0.55, alpha: 1)
        label.stringValue = message
        setContent(.message, animated: true)
        hideWork?.cancel()
        hideWork = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2000))
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
        let duration = 0.2
        if !reduceMotion, let layer = effect.layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: centeredScale(0.8, in: panel.frame.size))
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

    private func setContent(_ new: Content, animated: Bool) {
        content = new
        let width: CGFloat
        let mid = Metrics.height / 2
        switch new {
        case .wave(let locked):
            waveform.isHidden = false
            label.isHidden = true
            lock.isHidden = !locked
            var x = Metrics.padding
            if locked {
                lock.frame.origin = NSPoint(x: x, y: round(mid - lock.frame.height / 2))
                x += lock.frame.width + Metrics.lockGap
            }
            waveform.frame.origin = NSPoint(x: x, y: round(mid - Metrics.waveSize.height / 2))
            width = x + Metrics.waveSize.width + Metrics.padding
        case .message:
            waveform.isHidden = true
            lock.isHidden = true
            label.isHidden = false
            let textWidth = min(ceil(label.attributedStringValue.size().width) + 4, Metrics.maxLabel)
            let h: CGFloat = 16
            label.frame = NSRect(x: Metrics.textPadding, y: round(mid - h / 2), width: textWidth, height: h)
            width = Metrics.textPadding * 2 + textWidth
        }
        let target = frameFor(width: width)
        guard abs(target.width - panel.frame.width) > 0.5 || abs(target.minX - panel.frame.minX) > 0.5 else { return }
        if animated && visible && !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.invalidateShadow()
    }

    private func frameFor(width: CGFloat) -> NSRect {
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

    /// Set while the LLM is answering: the bars roll as a wave instead of following the mic.
    private var thinkingSince: CFTimeInterval?
    private var thinkingAnimated = true

    private let barWidth: CGFloat = 3.5
    private let minBarHeight: CGFloat = 3.5

    func start(levels: LevelBox, jitter: Bool) {
        self.levels = levels
        thinkingSince = nil
        envelope = WaveformEnvelope()
        envelope.jitter = jitter ? 0.04 : 0
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// Stop following the mic; bars decay to rest via the release curve.
    func idle() {
        levels = nil
        thinkingSince = nil
    }

    /// A slow wave rolling across the bars; with `animated` off (Reduce Motion), a still mid-height row.
    func think(animated: Bool) {
        levels = nil
        thinkingSince = CACurrentMediaTime()
        thinkingAnimated = animated
    }

    func stop() {
        link?.invalidate()
        link = nil
        levels = nil
        thinkingSince = nil
    }

    @objc private func tick() {
        if let since = thinkingSince {
            let t = CACurrentMediaTime() - since
            bars = (0..<bars.count).map { i in
                guard thinkingAnimated else { return 0.35 }
                let phase = t * 5 - Double(i) * 0.8
                return Float(0.2 + 0.4 * (0.5 + 0.5 * sin(phase)))
            }
        } else {
            envelope.step(target: levels?.get() ?? 0)
            bars = envelope.barLevels()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = CGFloat(bars.count)
        let spacing = (bounds.width - barWidth * count) / (count - 1)
        NSColor.white.withAlphaComponent(thinkingSince == nil ? 0.92 : 0.6).setFill()
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
