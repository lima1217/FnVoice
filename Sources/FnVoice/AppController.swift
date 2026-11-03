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

    private var armTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private var durationLimitTask: Task<Void, Never>?
    private var tapRetryTimer: Timer?
    private var targetPID: Int32?
    private var signpostState: OSSignpostIntervalState?

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
        legacyEngine.onPartial = { [weak self] text in self?.capsule.setText(text) }
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
            durationLimitTask?.cancel()
            signpostState = Log.signposter.beginInterval("release-to-inject")
            Task { @MainActor in
                await self.startTask?.value // Fn released while the engine was still starting
                let (text, error) = await self.active.finish()
                Log.asr.debug("final transcript: \(text, privacy: .private)")
                if let error {
                    self.send(.captureFailed(session: s, message: error))
                    return
                }
                let refine = self.settings.llmEnabled && self.llmConfig.isConfigured
                self.send(.transcriptFinal(session: s, text: text, refine: refine))
            }

        case .abortCapture:
            durationLimitTask?.cancel()
            startTask?.cancel()
            active.cancel()

        case .refine(let s, let text):
            capsule.showRefining()
            let refiner = Refiner(client: OpenAICompatibleClient(config: llmConfig))
            refineTask = Task { @MainActor in
                let outcome = await refiner.refine(text)
                if let reason = outcome.fallbackReason {
                    Log.llm.notice("refinement fell back to raw text: \(reason, privacy: .public)")
                }
                guard !Task.isCancelled else { return }
                self.send(.refined(session: s, text: outcome.text))
            }

        case .cancelRefine:
            refineTask?.cancel()
            refineTask = nil

        case .inject(let s, let text):
            capsule.setText(text)
            Task { @MainActor in
                var notice: String?
                do {
                    let report = try await self.injector.inject(text, expectedPID: self.targetPID)
                    Log.inject.info("""
                        injected switchedIS=\(report.switchedInputSource) restoredIS=\(report.inputSourceRestored) \
                        restoredClipboard=\(report.clipboardRestored)
                        """)
                    if !report.inputSourceRestored { notice = "Couldn't restore your input method" }
                } catch let e as InjectionError {
                    Log.inject.notice("injection refused: \(String(describing: e), privacy: .public)")
                    notice = e.userMessage
                } catch {
                    notice = error.localizedDescription
                }
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

    private func transcriber(for engine: RecognitionEngine) -> LiveTranscriber {
        guard engine != .legacy else { return legacyEngine }
        if let existing = analyzerEngines[engine] { return existing }
        guard #available(macOS 26.0, *) else { return legacyEngine }
        let created = AnalyzerCapture(engine: engine)
        created.onPartial = { [weak self] text in self?.capsule.setText(text) }
        analyzerEngines[engine] = created
        return created
    }

    private func startCapture(session s: Int) {
        for p in [Permission.microphone, .speechRecognition] where !Permissions.isGranted(p) {
            send(.captureFailed(session: s, message: "\(p.title) permission needed — see menu"))
            return
        }
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
        return Vocabulary.merged(user: user)
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
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        let configured = llmConfig.isConfigured
        let toggle = NSMenuItem(title: configured ? "Enabled" : "Enabled (not configured)", action: #selector(toggleLLM), keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.llmEnabled ? .on : .off
        llmMenu.addItem(toggle)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        llmMenu.addItem(settingsItem)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        let vocab = NSMenuItem(title: "Edit Vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        vocab.target = self
        menu.addItem(vocab)

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
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = RecognitionEngine(rawValue: raw) else { return }
        settings.recognitionEngine = engine
        Log.app.info("recognition engine → \(engine.rawValue, privacy: .public)")
    }

    @objc private func toggleLLM() {
        settings.llmEnabled.toggle()
        if settings.llmEnabled && !llmConfig.isConfigured { openSettings() }
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

    @objc private func editVocabulary() {
        ensureVocabularyFile()
        NSWorkspace.shared.open(Self.vocabularyURL)
    }
}
