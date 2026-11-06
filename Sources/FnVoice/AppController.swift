import AppKit
import FnVoiceCore
import os
import ServiceManagement

/// Owns the dictation state machine and performs its effects against the real system.
@MainActor final class AppController: NSObject, NSMenuDelegate {
    private let settings = AppSettings()
    private var machine = DictationMachine()
    private let hotkeys = HotkeyMonitor()
    private let legacyEngine = SpeechCapture()
    private var analyzerEngines: [RecognitionEngine: LiveTranscriber] = [:]
    /// The engine running the current dictation.
    private lazy var active: LiveTranscriber = legacyEngine
    private var startTask: Task<Void, Never>?
    private let capsule = CapsulePanel()
    private lazy var injector = TextInjector(
        pasteboard: SystemPasteboard(), inputSources: TISInputSources(),
        poster: CGKeystrokePoster(), system: SystemProbe()
    )
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController?
    private var apiKey = Keychain.readAPIKey()
    private let editWatcher = EditWatcher()

    private var armTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private var durationLimitTask: Task<Void, Never>?
    private var tapRetryTimer: Timer?
    private var targetPID: Int32?
    private var signpostState: OSSignpostIntervalState?
    /// Per-dictation timestamps for the latency log line.
    private var timing = LatencyTiming()

    private var llmConfig: LLMConfig {
        LLMConfig(baseURL: settings.llmBaseURL, apiKey: apiKey, model: settings.llmModel)
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        installEditMenu()
        legacyEngine.onPartial = { [weak self] text in self?.capsule.setText(TextFormatter.format(text)) }
        hotkeys.isCancellable = { [weak self] in self?.machine.phase.isCancellable ?? false }
        hotkeys.onAction = { [weak self] action in self?.handleKey(action) }
        installTapOrRetry()
        ensureVocabularyFile()

        Task { @MainActor in
            // Ask for what the system can prompt for; Accessibility/Input Monitoring are surfaced in the menu.
            for p in [Permission.microphone, .speechRecognition] where !Permissions.isGranted(p) {
                await Permissions.request(p)
            }
            if !Permissions.isGranted(.accessibility) { await Permissions.request(.accessibility) }
            self.showFnHintIfNeeded()
        }
        prewarm()
        Log.app.info("started; language=\(self.settings.language.rawValue, privacy: .public) engine=\(self.resolvedEngine.rawValue, privacy: .public)")
    }

    // MARK: - Hotkey → state machine

    private func handleKey(_ action: KeyAction) {
        switch action {
        case .fnDown: send(.fnDown)
        case .fnUp: send(.fnUp)
        case .comboKey: send(.comboKey)
        case .escape: send(.cancel)
        }
    }

    private func send(_ event: DictationEvent) {
        let before = machine.phase
        let effects = machine.send(event)
        if before != machine.phase {
            Log.app.debug("phase \(String(describing: before), privacy: .public) → \(String(describing: self.machine.phase), privacy: .public)")
        }
        updateIcon(recording: machine.phase == .recording)
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: DictationEffect) {
        switch effect {
        case .scheduleArm(let s):
            targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            armTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self.send(.armElapsed(session: s))
            }

        case .cancelArm:
            armTask?.cancel()
            armTask = nil

        case .startCapture(let s):
            startCapture(session: s)

        case .stopCapture(let s):
            timing.release = .now
            durationLimitTask?.cancel()
            signpostState = Log.signposter.beginInterval("release-to-inject")
            Task { @MainActor in
                await self.startTask?.value // Fn released while the engine was still starting
                let (heard, error) = await self.active.finish()
                self.timing.asrDone = .now
                Log.asr.debug("final transcript: \(heard, privacy: .private)")
                if let error {
                    self.send(.captureFailed(session: s, message: error))
                    return
                }
                // Mistakes the user corrected twice are fixed here, without the LLM.
                let corrections = self.loadCorrections()
                let text = corrections.apply(heard)
                // Pure-Chinese text was almost always right in the eval: skip the LLM round trip for it.
                let refine = self.settings.llmEnabled && self.llmConfig.isConfigured
                    && (RefinementGate.shouldRefine(text, scope: self.settings.refinementScope)
                        || corrections.mentionsKnownMistake(text))
                self.send(.transcriptFinal(session: s, text: text, refine: refine))
            }

        case .abortCapture:
            durationLimitTask?.cancel()
            startTask?.cancel()
            active.cancel()

        case .refine(let s, let text):
            capsule.showRefining()
            let refiner = Refiner(
                client: OpenAICompatibleClient(config: llmConfig), vocabulary: currentVocabulary(),
                corrections: loadCorrections().hints()
            )
            refineTask = Task { @MainActor in
                self.timing.refineStart = .now
                let outcome = await refiner.refine(text)
                self.timing.refineDone = .now
                if let reason = outcome.fallbackReason {
                    Log.llm.notice("refinement fell back to raw text: \(reason, privacy: .public)")
                }
                guard !Task.isCancelled else { return }
                self.send(.refined(session: s, text: outcome.text))
            }

        case .cancelRefine:
            refineTask?.cancel()
            refineTask = nil

        case .inject(let s, let raw):
            let text = TextFormatter.format(raw)
            capsule.setText(text)
            Task { @MainActor in
                var notice: String?
                do {
                    let report = try await self.injector.inject(text, expectedPID: self.targetPID) {
                        self.timing.pasted = .now
                    }
                    Log.inject.info("""
                        injected switchedIS=\(report.switchedInputSource) restoredIS=\(report.inputSourceRestored) \
                        restoredClipboard=\(report.clipboardRestored)
                        """)
                    if !report.inputSourceRestored { notice = "Couldn't restore your input method" }
                    if self.settings.learnFromCorrections, let pid = self.targetPID {
                        self.editWatcher.watch(pasted: text, pid: pid) { [weak self] found in self?.learn(found) }
                    }
                } catch let e as InjectionError {
                    Log.inject.notice("injection refused: \(String(describing: e), privacy: .public)")
                    notice = e.userMessage
                } catch {
                    notice = error.localizedDescription
                }
                self.timing.log(
                    engine: self.active is SpeechCapture ? "legacy" : self.resolvedEngine.rawValue,
                    partials: self.active.partialsDuringCapture
                )
                if let state = self.signpostState {
                    Log.signposter.endInterval("release-to-inject", state)
                    self.signpostState = nil
                }
                self.send(.injected(session: s, notice: notice))
            }

        case .hideCapsule:
            capsule.dismiss()

        case .notify(let message):
            capsule.flash(message)
        }
    }

    static var analyzerAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private var resolvedEngine: RecognitionEngine {
        RecognitionEngine.resolve(stored: settings.recognitionEngine, analyzerAvailable: Self.analyzerAvailable)
    }

    /// Loads the current engine's model in the background so the first Fn press is fast.
    private func prewarm() {
        let engine = resolvedEngine
        let language = settings.language
        guard engine != .legacy, #available(macOS 26.0, *) else { return }
        let fast = settings.showLiveText
        Task { @MainActor in await AnalyzerSession.prewarm(engine: engine, language: language, fast: fast) }
    }

    private func transcriber(for engine: RecognitionEngine) -> LiveTranscriber {
        guard engine != .legacy else { return legacyEngine }
        if let existing = analyzerEngines[engine] { return existing }
        guard #available(macOS 26.0, *) else { return legacyEngine }
        let created = AnalyzerCapture(engine: engine) { [weak self] in self?.settings.showLiveText ?? true }
        created.onPartial = { [weak self] text in self?.capsule.setText(TextFormatter.format(text)) }
        analyzerEngines[engine] = created
        return created
    }

    private func startCapture(session s: Int) {
        // Whatever the user fixed in the previous dictation is learned before this one is recognized.
        editWatcher.stop()
        for p in [Permission.microphone, .speechRecognition] where !Permissions.isGranted(p) {
            send(.captureFailed(session: s, message: "\(p.title) permission needed — see menu"))
            return
        }
        timing = LatencyTiming(press: .now)
        let engine = transcriber(for: resolvedEngine)
        let language = settings.language
        let vocabulary = currentVocabulary()
        active = engine
        capsule.show(levels: engine.levels)
        startTask = Task { @MainActor in
            do {
                do {
                    try await engine.start(language: language, vocabulary: vocabulary)
                } catch CaptureError.modelDownloading {
                    // The SpeechAnalyzer model for this language is downloading; dictate with legacy meanwhile.
                    Log.asr.notice("analyzer model not installed for \(language.rawValue, privacy: .public); using legacy for now")
                    self.active = self.legacyEngine
                    self.capsule.show(levels: self.legacyEngine.levels)
                    try self.legacyEngine.start(language: language, vocabulary: vocabulary)
                }
            } catch let e as CaptureError {
                self.send(.captureFailed(session: s, message: e.userMessage))
                return
            } catch is CancellationError {
                return
            } catch {
                self.send(.captureFailed(session: s, message: error.localizedDescription))
                return
            }
            self.timing.ready = .now
            // Server-based recognition stops at ~1 minute; finalize just before rather than losing audio.
            if !self.active.isOnDevice {
                self.durationLimitTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(55))
                    guard !Task.isCancelled else { return }
                    Log.asr.notice("approaching server recognition limit; finalizing")
                    self.send(.fnUp)
                }
            }
        }
    }

    /// A menu-bar-only app has no visible main menu, but AppKit still routes ⌘V/⌘C/⌘X/⌘A/⌘Z in
    /// text fields through the main menu's key equivalents. Without it, pasting an API key does nothing.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit FnVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Event tap / permissions

    private func installTapOrRetry() {
        if hotkeys.install() { return }
        tapRetryTimer?.invalidate()
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hotkeys.install() else { return }
                self.tapRetryTimer?.invalidate()
                self.tapRetryTimer = nil
            }
        }
    }

    private func showFnHintIfNeeded() {
        guard FnUsageType.needsHint(rawValue: Self.fnUsageRaw()), !settings.fnHintShown else { return }
        settings.fnHintShown = true
        let alert = NSAlert()
        alert.messageText = "Set the 🌐/Fn key to “Do Nothing”"
        alert.informativeText = """
            FnVoice suppresses the Fn key while you dictate, but macOS may still open the emoji picker, \
            switch input source or start Apple Dictation. In System Settings → Keyboard, set \
            “Press 🌐 key to” to “Do Nothing”.
            """
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Later")
        NSApp.forceActivate()
        if alert.runModal() == .alertFirstButtonReturn { openKeyboardSettings() }
    }

    private static func fnUsageRaw() -> Int? {
        (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? NSNumber)?.intValue
    }

    private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    // MARK: - Vocabulary

    static var vocabularyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FnVoice", isDirectory: true)
        return dir.appendingPathComponent("vocabulary.txt")
    }

    private func ensureVocabularyFile() {
        let url = Self.vocabularyURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Vocabulary.fileTemplate.write(to: url, atomically: true, encoding: .utf8)
    }

    private func currentVocabulary() -> [String] {
        let user = (try? String(contentsOf: Self.vocabularyURL, encoding: .utf8)).map(Vocabulary.parse) ?? []
        return Vocabulary.merged(user: user + loadCorrections().vocabularyTerms())
    }

    // MARK: - Learned corrections

    static var correctionsURL: URL {
        vocabularyURL.deletingLastPathComponent().appendingPathComponent("corrections.txt")
    }

    /// Read fresh each time so hand edits to the file apply to the next dictation.
    private func loadCorrections() -> CorrectionStore {
        (try? String(contentsOf: Self.correctionsURL, encoding: .utf8)).map(CorrectionStore.parse) ?? CorrectionStore()
    }

    private func learn(_ found: [Correction]) {
        var store = loadCorrections()
        let promoted = store.record(found)
        let url = Self.correctionsURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try store.serialized().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("saving corrections failed: \(error.localizedDescription, privacy: .public)")
        }
        Log.app.info("learned \(found.count) correction(s); \(promoted.count) now auto-applied")
        if let c = promoted.first, machine.phase == .idle {
            capsule.flash("Learned: \(c.wrong) → \(c.right)")
        }
    }

    // MARK: - Menu

    private func updateIcon(recording: Bool) {
        let name = recording ? "mic.fill" : "mic"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "FnVoice")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !hotkeys.isInstalled { _ = hotkeys.install() }

        let header = NSMenuItem(title: "Hold Fn to dictate · Esc to cancel", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let missing = Permissions.missing
        if !missing.isEmpty {
            menu.addItem(.separator())
            for p in missing {
                let item = NSMenuItem(title: "⚠︎ Grant \(p.title) (\(p.purpose))…", action: #selector(grantPermission(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.title
                menu.addItem(item)
            }
        }
        if FnUsageType.needsHint(rawValue: Self.fnUsageRaw()) {
            let item = NSMenuItem(title: "⚠︎ Set “Press 🌐 key to” → Do Nothing…", action: #selector(openKeyboardSettingsAction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for lang in DictationLanguage.allCases {
            let item = NSMenuItem(title: lang.displayName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = lang == settings.language ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let engineItem = NSMenuItem(title: "Recognition Engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        let current = resolvedEngine
        for engine in RecognitionEngine.allCases {
            let item = NSMenuItem(title: engine.displayName, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = engine.rawValue
            item.state = engine == current ? .on : .off
            if engine.requiresMacOS26 && !Self.analyzerAvailable {
                item.isEnabled = false
                item.action = nil
            }
            engineMenu.addItem(item)
        }
        engineMenu.addItem(.separator())
        let live = NSMenuItem(title: "Show Live Text While Speaking", action: #selector(toggleLiveText), keyEquivalent: "")
        live.target = self
        live.state = settings.showLiveText ? .on : .off
        live.toolTip = "SpeechTranscriber: shows text as you speak, slightly less accurate. Off = more accurate, text appears on release."
        if current != .speechTranscriber {
            // Only SpeechTranscriber has the trade-off; the legacy engine always streams.
            live.isEnabled = false
            live.action = nil
        }
        engineMenu.addItem(live)
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        let configured = llmConfig.isConfigured
        let toggle = NSMenuItem(title: configured ? "Enabled" : "Enabled (not configured)", action: #selector(toggleLLM), keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.llmEnabled ? .on : .off
        llmMenu.addItem(toggle)
        llmMenu.addItem(.separator())
        for scope in RefinementScope.allCases {
            let item = NSMenuItem(title: scope.displayName, action: #selector(selectRefinementScope(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scope.rawValue
            item.state = scope == settings.refinementScope ? .on : .off
            llmMenu.addItem(item)
        }
        llmMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        llmMenu.addItem(settingsItem)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        let vocab = NSMenuItem(title: "Edit Vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        vocab.target = self
        menu.addItem(vocab)

        let learnItem = NSMenuItem(title: "Learned Corrections", action: nil, keyEquivalent: "")
        let learnMenu = NSMenu()
        let learnToggle = NSMenuItem(title: "Learn From My Edits", action: #selector(toggleLearning), keyEquivalent: "")
        learnToggle.target = self
        learnToggle.state = settings.learnFromCorrections ? .on : .off
        learnToggle.toolTip = "After pasting, watch how you fix words in that field. A fix seen twice is applied automatically."
        learnMenu.addItem(learnToggle)
        let count = loadCorrections().entries.count
        let editLearned = NSMenuItem(title: "Edit Learned Corrections (\(count))…", action: #selector(editCorrections), keyEquivalent: "")
        editLearned.target = self
        learnMenu.addItem(editLearned)
        learnItem.submenu = learnMenu
        menu.addItem(learnItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval:
            // Registered, but the user switched it off in System Settings › General › Login Items.
            loginItem.state = .mixed
            loginItem.title = "Launch at Login (needs approval in System Settings)"
        default: loginItem.state = .off
        }
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FnVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func grantPermission(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let p = Permission.allCases.first(where: { $0.title == title }) else { return }
        Task { @MainActor in
            await Permissions.request(p)
            if p == .accessibility { self.installTapOrRetry() }
        }
    }

    @objc private func openKeyboardSettingsAction() { openKeyboardSettings() }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = DictationLanguage(rawValue: raw) else { return }
        settings.language = lang
        prewarm()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = RecognitionEngine(rawValue: raw) else { return }
        settings.recognitionEngine = engine
        prewarm()
        Log.app.info("recognition engine → \(engine.rawValue, privacy: .public)")
    }

    @objc private func toggleLiveText() {
        settings.showLiveText.toggle()
        Log.app.info("live text → \(self.settings.showLiveText)")
        prewarm()
    }

    @objc private func toggleLLM() {
        settings.llmEnabled.toggle()
        if settings.llmEnabled && !llmConfig.isConfigured { openSettings() }
    }

    @objc private func selectRefinementScope(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scope = RefinementScope(rawValue: raw) else { return }
        settings.refinementScope = scope
        Log.app.info("refinement scope → \(scope.rawValue, privacy: .public)")
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] in
                self?.apiKey = Keychain.readAPIKey()
            }
        }
        settingsWindow?.present()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            Log.app.error("launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
            capsule.flash("Launch at Login failed: \(error.localizedDescription)")
        }
        Log.app.info("launch-at-login status=\(service.status.rawValue)")
    }

    @objc private func toggleLearning() {
        settings.learnFromCorrections.toggle()
        if !settings.learnFromCorrections { editWatcher.stop() }
    }

    @objc private func editCorrections() {
        let url = Self.correctionsURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? CorrectionStore().serialized().write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func editVocabulary() {
        ensureVocabularyFile()
        NSWorkspace.shared.open(Self.vocabularyURL)
    }
}

/// Timestamps of one dictation. Logged as one line, e.g.
/// `latency engine=speechTranscriber partials=12 setup=120ms asr=310ms llm=640ms paste=95ms release→text=1045ms`.
struct LatencyTiming {
    var press: ContinuousClock.Instant?
    var ready: ContinuousClock.Instant?
    var release: ContinuousClock.Instant?
    var asrDone: ContinuousClock.Instant?
    var refineStart: ContinuousClock.Instant?
    var refineDone: ContinuousClock.Instant?
    var pasted: ContinuousClock.Instant?

    static func ms(_ a: ContinuousClock.Instant?, _ b: ContinuousClock.Instant?) -> String {
        guard let a, let b else { return "-" }
        return "\(Int((b - a) / .milliseconds(1)))ms"
    }

    func log(engine: String, partials: Int) {
        let pasteFrom = refineDone ?? asrDone
        let line = "engine=\(engine) partials=\(partials) setup=\(Self.ms(press, ready)) asr=\(Self.ms(release, asrDone)) "
            + "llm=\(Self.ms(refineStart, refineDone)) paste=\(Self.ms(pasteFrom, pasted)) release→text=\(Self.ms(release, pasted))"
        // Notice, not info: info lines live only in the process's memory buffer and vanish when
        // the app is restarted (every `make install`), so `log show --last 7d` showed almost nothing.
        // This line carries only numbers, never transcript text, so persisting it is safe.
        Log.app.notice("latency \(line, privacy: .public)")
    }
}
