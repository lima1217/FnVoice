import AppKit
import AVFoundation
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
    private var tapWindowTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private var durationLimitTask: Task<Void, Never>?
    private var tapRetryTimer: Timer?
    /// Kept alive after `warmUpAudioInput`; see there.
    private var audioWarmup: AVAudioEngine?
    private var targetPID: Int32?
    /// Whether the field focused at Fn-down can be read back through Accessibility, which decides
    /// between typing the raw text at once (and swapping the LLM's answer in later) and waiting.
    private var targetReadable = false
    /// The target app's display name, given to the LLM.
    private var targetAppName: String?
    private var signpostState: OSSignpostIntervalState?
    /// Per-dictation timestamps for the latency log line.
    private var timing = LatencyTiming()
    /// The dictation being recorded for history.jsonl, tagged with its session so a late result
    /// from a cancelled dictation can't overwrite the current one.
    private var record: (session: Int, value: DictationRecord)?

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
        hotkeys.isCancellable = { [weak self] in self?.machine.phase.isCancellable ?? false }
        hotkeys.onAction = { [weak self] action in self?.handleKey(action) }
        installTapOrRetry()
        ensureVocabularyFile()

        Task { @MainActor in
            // Ask for what the system can prompt for; Accessibility/Input Monitoring are surfaced in the menu.
            for p in [Permission.microphone, .speechRecognition] where !Permissions.isGranted(p) {
                await Permissions.request(p)
            }
            self.warmUpAudioInput()
            if !Permissions.isGranted(.accessibility) { await Permissions.request(.accessibility) }
            self.showFnHintIfNeeded()
        }
        prewarm()
        // The last dictation's edit watch is still open at quit; finalize it so its history line is written.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.editWatcher.stop() } }
        Log.app.info("started; language=\(self.settings.language.rawValue, privacy: .public) engine=\(self.resolvedEngine.rawValue, privacy: .public)")
    }

    // MARK: - Hotkey → state machine

    /// `--first-press [--after <seconds>]`: one synthetic Fn press and release `after` seconds
    /// past launch, then exit 0 if the press-to-ready setup stayed under `firstPressBudget`.
    /// `make coldstart` runs it after a cold gap; nothing in `make check` opens the mic, so this
    /// is the only loop that sees the first-press cost (see `warmUpAudioInput`).
    static let firstPressBudget: Duration = .milliseconds(500)

    func firstPressBench(after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            self.handleKey(.fnDown)
            try? await Task.sleep(for: .milliseconds(1500))
            self.handleKey(.fnUp)
            try? await Task.sleep(for: .seconds(3))
            guard let press = self.timing.press, let ready = self.timing.ready else {
                print("FIRSTPRESS: FAIL (capture never became ready)")
                exit(1)
            }
            let setup = ready - press
            let ok = setup <= Self.firstPressBudget
            print("first-press setup=\(Int(setup / .milliseconds(1)))ms after=\(Int(delay / .seconds(1)))s")
            print(ok ? "FIRSTPRESS: PASS" : "FIRSTPRESS: FAIL (budget \(Self.firstPressBudget))")
            exit(ok ? 0 : 1)
        }
    }

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

        case .scheduleTapWindow(let s):
            tapWindowTask = Task { @MainActor in
                try? await Task.sleep(for: DictationMachine.tapWindow)
                guard !Task.isCancelled else { return }
                self.send(.tapWindowElapsed(session: s))
            }

        case .cancelTapWindow:
            tapWindowTask?.cancel()
            tapWindowTask = nil

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
                let llmOn = self.settings.llmEnabled && self.llmConfig.isConfigured
                let refine = llmOn
                    && (RefinementGate.shouldRefine(text, scope: self.settings.refinementScope)
                        || corrections.mentionsKnownMistake(text))
                var entry = DictationRecord(
                    engine: self.activeEngineName, language: self.settings.language.rawValue,
                    raw: heard, input: text, llm: refine ? .ok : (llmOn ? .skipped : .off)
                )
                entry.partials = self.active.partialsDuringCapture
                entry.app = self.targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
                entry.fieldReadable = self.targetReadable
                entry.appName = self.targetAppName
                self.record = (s, entry)
                // Type first when the answer can be swapped in later; otherwise the user waits for it.
                let plan: RefinementPlan = !refine ? .none : (self.targetReadable ? .afterTyping : .beforeTyping)
                self.timing.typedFirst = plan == .afterTyping
                self.send(.transcriptFinal(session: s, text: text, refine: plan))
            }

        case .abortCapture:
            durationLimitTask?.cancel()
            startTask?.cancel()
            active.cancel()

        case .showRefining:
            capsule.showRefining()

        case .refine(let s, let text):
            let refiner = Refiner(
                client: OpenAICompatibleClient(config: llmConfig), vocabulary: currentVocabulary(),
                corrections: loadCorrections().hints()
            )
            let app = targetAppName
            refineTask = Task { @MainActor in
                self.timing.refineStart = .now
                let outcome = await refiner.refine(text, app: app)
                self.timing.refineDone = .now
                if outcome.reverted > 0 {
                    Log.llm.notice("guardrail put back \(outcome.reverted, privacy: .public) change(s) and kept the rest")
                }
                if let reason = outcome.fallbackReason {
                    Log.llm.notice("refinement fell back to raw text: \(reason, privacy: .public)")
                }
                if self.record?.session == s {
                    self.record?.value.llm = DictationRecord.status(fallbackReason: outcome.fallbackReason)
                    self.record?.value.llmReason = outcome.fallbackReason
                    self.record?.value.model = self.settings.llmModel
                    self.record?.value.refined = outcome.usedLLM ? outcome.text : nil
                    self.record?.value.rejected = outcome.rejected
                }
                guard !Task.isCancelled else { return }
                self.send(.refined(session: s, text: outcome.text))
            }

        case .cancelRefine:
            refineTask?.cancel()
            refineTask = nil
            // A type-first dictation abandoned by the next Fn press: its text stays as typed.
            if record?.value.pasted != nil { record?.value.llm = .abandoned }

        case .inject(let s, let raw):
            let text = TextFormatter.format(raw)
            Task { @MainActor in
                var notice: String?
                var typed = false
                do {
                    let report = try await self.injector.inject(text, expectedPID: self.targetPID) {
                        self.timing.pasted = .now
                    }
                    Log.inject.info("""
                        injected switchedIS=\(report.switchedInputSource) restoredIS=\(report.inputSourceRestored) \
                        restoredClipboard=\(report.clipboardRestored)
                        """)
                    if !report.inputSourceRestored { notice = "Couldn't restore your input method" }
                    self.timing.injectDone = .now
                    typed = true
                    if self.record?.session == s { self.record?.value.pasted = text }
                } catch let e as InjectionError {
                    Log.inject.notice("injection refused: \(String(describing: e), privacy: .public)")
                    notice = e.userMessage
                    if self.record?.session == s { self.record?.value.injectError = String(describing: e) }
                } catch {
                    notice = error.localizedDescription
                    if self.record?.session == s { self.record?.value.injectError = error.localizedDescription }
                }
                if let state = self.signpostState {
                    Log.signposter.endInterval("release-to-inject", state)
                    self.signpostState = nil
                }
                self.send(.injected(session: s, notice: notice, typed: typed))
            }

        case .replace(let s, let refined):
            Task { @MainActor in
                var notice: String?
                let text = TextFormatter.format(refined)
                if let (session, entry) = self.record, session == s, let typed = entry.pasted, text != typed,
                   let pid = self.targetPID {
                    let outcome = await InPlaceReplacer.replace(typed, with: text, pid: pid, injector: self.injector) {
                        self.timing.replaced = .now
                    }
                    switch outcome {
                    case .replaced:
                        self.record?.value.replaced = text
                        Log.inject.info("replaced in place")
                    case .skipped(let why):
                        self.record?.value.replaceError = "skipped: \(why)"
                        Log.inject.info("in-place replace skipped: \(why, privacy: .public)")
                    case .failed(let why):
                        self.record?.value.replaceError = why
                        Log.inject.notice("in-place replace failed: \(why, privacy: .public)")
                        notice = why
                    }
                }
                self.send(.replaced(session: s, notice: notice))
            }

        case .settle(let s):
            settle(session: s)

        case .hideCapsule:
            capsule.dismiss()

        case .notify(let message):
            capsule.flash(message)
        }
    }

    /// Ends a dictation's bookkeeping once its text is where it will stay: logs the latency line,
    /// and either watches the field for the user's edits (which also writes the history line when
    /// the watch settles) or writes the history line now. The machine emits `.settle` once per
    /// dictation; the guard only covers a record it never got to (nothing heard, cancelled).
    private func settle(session s: Int) {
        guard let (session, entry) = record, session == s else { return }
        record = nil
        timing.log(engine: activeEngineName, partials: active.partialsDuringCapture)
        let timed = timing.fill(entry)
        let learning = settings.learnFromCorrections
        if learning || settings.keepHistory, let typed = entry.typed, let pid = targetPID {
            editWatcher.watch(pasted: typed, pid: pid) { [weak self] found in
                if self?.settings.learnFromCorrections == true { self?.learn(found) }
            } onSettled: { [weak self] final in
                var timed = timed
                timed.final = final
                self?.saveHistory(timed)
            }
        } else {
            saveHistory(timed)
        }
    }

    /// Locked (double-tap) recording finalizes on its own after this long.
    static let lockedRecordingLimit: Duration = .seconds(600)

    static var analyzerAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Engine name for logs and history: the legacy fallback may stand in for the chosen engine.
    private var activeEngineName: String {
        active is SpeechCapture ? "legacy" : resolvedEngine.rawValue
    }

    private var resolvedEngine: RecognitionEngine {
        RecognitionEngine.resolve(stored: settings.recognitionEngine, analyzerAvailable: Self.analyzerAvailable)
    }

    /// The first `AVAudioEngine.inputNode` access in a process brings up CoreAudio's input path:
    /// 1.9–2.4 s measured cold, under 60 ms for every access after it for the rest of the process,
    /// whichever engine instance asks. That cost sat on the first Fn press after launch (the
    /// `setup=2100ms` lines) and nothing else, since `make bench`/`make smoke` feed files and
    /// never open the mic. Pay it here, off the main thread, as soon as the mic permission is in
    /// (without it the access would prompt). The engine stays alive so the warm path does too.
    private func warmUpAudioInput() {
        guard audioWarmup == nil, Permissions.isGranted(.microphone) else { return }
        let engine = AVAudioEngine()
        audioWarmup = engine
        nonisolated(unsafe) let warm = engine // touched only here, never started
        Task.detached(priority: .utility) {
            let t = ContinuousClock.now
            _ = warm.inputNode
            Log.audio.info("audio input warmed in \(Int((ContinuousClock.now - t) / .milliseconds(1)))ms")
        }
    }

    /// Loads the current engine's model in the background so the first Fn press is fast.
    private func prewarm() {
        let engine = resolvedEngine
        let language = settings.language
        guard engine != .legacy, #available(macOS 26.0, *) else { return }
        Task { @MainActor in await AnalyzerSession.prewarm(engine: engine, language: language) }
    }

    private func transcriber(for engine: RecognitionEngine) -> LiveTranscriber {
        guard engine != .legacy else { return legacyEngine }
        if let existing = analyzerEngines[engine] { return existing }
        guard #available(macOS 26.0, *) else { return legacyEngine }
        let created = AnalyzerCapture(engine: engine)
        analyzerEngines[engine] = created
        return created
    }

    private func startCapture(session s: Int) {
        // Whatever the user fixed in the previous dictation is learned before this one is recognized.
        editWatcher.stop()
        record = nil
        for p in [Permission.microphone, .speechRecognition] where !Permissions.isGranted(p) {
            send(.captureFailed(session: s, message: "需要“\(p.title)”权限，请查看菜单"))
            return
        }
        timing = LatencyTiming(press: .now)
        // Decided now, while the field the user is dictating into still has focus.
        targetReadable = targetPID.map(EditWatcher.canReadFocusedField) ?? false
        targetAppName = targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        Log.app.debug("target field readable: \(self.targetReadable)")
        let engine = transcriber(for: resolvedEngine)
        let language = settings.language
        let vocabulary = currentVocabulary()
        active = engine
        let locked = machine.locked
        capsule.show(levels: engine.levels, locked: locked)
        startTask = Task { @MainActor in
            do {
                do {
                    try await engine.start(language: language, vocabulary: vocabulary)
                } catch CaptureError.modelDownloading {
                    // The SpeechAnalyzer model for this language is downloading; dictate with legacy meanwhile.
                    Log.asr.notice("analyzer model not installed for \(language.rawValue, privacy: .public); using legacy for now")
                    self.active = self.legacyEngine
                    self.capsule.show(levels: self.legacyEngine.levels, locked: locked)
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
            // Locked recording gets a generous cap so a forgotten lock doesn't keep the mic open forever.
            let limit: Duration? = !self.active.isOnDevice ? .seconds(55) : (locked ? Self.lockedRecordingLimit : nil)
            if let limit {
                self.durationLimitTask = Task { @MainActor in
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    Log.asr.notice("recording limit reached; finalizing")
                    self.send(.finish(session: s))
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
        alert.messageText = "建议把 🌐 键设为“不执行任何操作”"
        alert.informativeText = """
            FnVoice 听写时会拦截 Fn 键，但 macOS 仍可能同时弹出表情面板、切换输入法或启动系统听写。\
            请在“系统设置 › 键盘”中，把“按下 🌐 键时”改为“不执行任何操作”。
            """
        alert.addButton(withTitle: "打开键盘设置")
        alert.addButton(withTitle: "以后再说")
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

    static var historyURL: URL {
        vocabularyURL.deletingLastPathComponent().appendingPathComponent("history.jsonl")
    }

    private func saveHistory(_ entry: DictationRecord) {
        guard settings.keepHistory else { return }
        do {
            try DictationHistory.append(entry, to: Self.historyURL)
        } catch {
            Log.app.notice("history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

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

        menu.addItem(headerItem())

        let missing = Permissions.missing
        if !missing.isEmpty {
            menu.addItem(.separator())
            for p in missing {
                let item = menuItem("授予“\(p.title)”权限…", symbol: "exclamationmark.triangle.fill",
                                    action: #selector(grantPermission(_:)))
                item.image = Self.symbol("exclamationmark.triangle.fill", color: .systemOrange)
                item.toolTip = p.purpose
                item.representedObject = p.title
                menu.addItem(item)
            }
        }

        // Dictation
        menu.addItem(.separator())
        let languageMenu = NSMenu()
        for lang in DictationLanguage.allCases {
            let item = menuItem(lang.displayName, action: #selector(selectLanguage(_:)))
            item.representedObject = lang.rawValue
            item.state = lang == settings.language ? .on : .off
            languageMenu.addItem(item)
        }
        menu.addItem(submenuItem("语言", symbol: "globe", submenu: languageMenu))

        let engineMenu = NSMenu()
        let current = resolvedEngine
        for engine in RecognitionEngine.allCases {
            let unavailable = engine.requiresMacOS26 && !Self.analyzerAvailable
            let item = menuItem(engine.displayName, action: unavailable ? nil : #selector(selectEngine(_:)))
            item.representedObject = engine.rawValue
            item.state = engine == current ? .on : .off
            item.isEnabled = !unavailable
            engineMenu.addItem(item)
        }
        menu.addItem(submenuItem("识别引擎", symbol: "waveform", submenu: engineMenu))

        let llmMenu = NSMenu()
        let toggle = menuItem(llmConfig.isConfigured ? "启用" : "启用（尚未配置 API）", action: #selector(toggleLLM))
        toggle.state = settings.llmEnabled ? .on : .off
        llmMenu.addItem(toggle)
        llmMenu.addItem(.separator())
        llmMenu.addItem(NSMenuItem.sectionHeader(title: "精修范围"))
        for scope in RefinementScope.allCases {
            let item = menuItem(scope.displayName, action: #selector(selectRefinementScope(_:)))
            item.representedObject = scope.rawValue
            item.state = scope == settings.refinementScope ? .on : .off
            llmMenu.addItem(item)
        }
        llmMenu.addItem(.separator())
        llmMenu.addItem(menuItem("API 设置…", action: #selector(openSettings)))
        menu.addItem(submenuItem("AI 精修", symbol: "sparkles", submenu: llmMenu))

        // Words
        menu.addItem(.separator())
        menu.addItem(menuItem("编辑词汇表…", symbol: "character.book.closed", action: #selector(editVocabulary)))

        let learnMenu = NSMenu()
        let learnToggle = menuItem("从我的修改中学习", action: #selector(toggleLearning))
        learnToggle.state = settings.learnFromCorrections ? .on : .off
        learnToggle.toolTip = "听写后留意你在输入框里怎么改词，同一处修改出现两次后自动替换。"
        learnMenu.addItem(learnToggle)
        let count = loadCorrections().entries.count
        learnMenu.addItem(menuItem(count > 0 ? "查看已学纠错（\(count) 条）…" : "查看已学纠错…", action: #selector(editCorrections)))
        menu.addItem(submenuItem("自动纠错", symbol: "wand.and.stars", submenu: learnMenu))

        let historyMenu = NSMenu()
        let keep = menuItem("保留历史", action: #selector(toggleHistory))
        keep.state = settings.keepHistory ? .on : .off
        keep.toolTip = "把每次听写的文本、耗时和你最终改定的文字保存在本机，不会上传。"
        historyMenu.addItem(keep)
        historyMenu.addItem(menuItem("在访达中显示…", action: #selector(revealHistory)))
        menu.addItem(submenuItem("听写历史", symbol: "clock.arrow.circlepath", submenu: historyMenu))

        // App
        menu.addItem(.separator())
        let loginItem = menuItem("登录时启动", symbol: "power", action: #selector(toggleLaunchAtLogin))
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval:
            // Registered, but the user switched it off in System Settings › General › Login Items.
            loginItem.state = .mixed
            loginItem.toolTip = "需在“系统设置 › 通用 › 登录项”中允许"
        default: loginItem.state = .off
        }
        menu.addItem(loginItem)
        menu.addItem(menuItem("关于 FnVoice", symbol: "info.circle", action: #selector(showAbout)))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 FnVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = Self.symbol("rectangle.portrait.and.arrow.right")
        menu.addItem(quit)
    }

    /// App name with the gesture cheat sheet underneath, as one non-clickable row.
    private func headerItem() -> NSMenuItem {
        let item = NSMenuItem(title: "FnVoice", action: nil, keyEquivalent: "")
        let title = NSMutableAttributedString(string: "FnVoice", attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor,
        ])
        title.append(NSAttributedString(string: "\n按住 Fn 说话 · 双击 Fn 锁定 · Esc 取消", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = title
        item.image = Self.symbol("mic.circle.fill", color: .controlAccentColor, pointSize: 22)
        item.isEnabled = false
        return item
    }

    private func menuItem(_ title: String, symbol: String? = nil, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol { item.image = Self.symbol(symbol) }
        return item
    }

    private func submenuItem(_ title: String, symbol: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = Self.symbol(symbol)
        item.submenu = submenu
        return item
    }

    private static func symbol(_ name: String, color: NSColor? = nil, pointSize: CGFloat? = nil) -> NSImage? {
        guard var image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: pointSize ?? NSFont.systemFontSize, weight: .regular)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        image = image.withSymbolConfiguration(config) ?? image
        image.isTemplate = color == nil
        return image
    }

    @objc private func showAbout() {
        NSApp.forceActivate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func grantPermission(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let p = Permission.allCases.first(where: { $0.title == title }) else { return }
        Task { @MainActor in
            await Permissions.request(p)
            if p == .accessibility { self.installTapOrRetry() }
            if p == .microphone { self.warmUpAudioInput() }
        }
    }


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

    @objc private func toggleHistory() {
        settings.keepHistory.toggle()
    }

    @objc private func revealHistory() {
        let url = Self.historyURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
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
/// `latency engine=speechTranscriber partials=12 setup=120ms asr=310ms llm=640ms paste=95ms release→text=1045ms cleanup=305ms replace=-`.
/// For a type-first dictation `paste` and `release→text` run from the recognizer, not the LLM,
/// and `replace` is LLM answer → swapped in. `cleanup` is the injector's housekeeping after the
/// text appeared (input source switched back, clipboard restored); nothing the user waits for,
/// but it gates the capsule's dismissal and the edit watch.
struct LatencyTiming {
    var press: ContinuousClock.Instant?
    var ready: ContinuousClock.Instant?
    var release: ContinuousClock.Instant?
    var asrDone: ContinuousClock.Instant?
    var refineStart: ContinuousClock.Instant?
    var refineDone: ContinuousClock.Instant?
    var pasted: ContinuousClock.Instant?
    /// The injector returned: input source and clipboard are back as they were.
    var injectDone: ContinuousClock.Instant?
    var replaced: ContinuousClock.Instant?
    /// The raw text was typed before the LLM answered.
    var typedFirst = false

    /// What the paste waited for: the recognizer, or the LLM when the text was held for it.
    private var pasteFrom: ContinuousClock.Instant? { typedFirst ? asrDone : (refineDone ?? asrDone) }

    static func ms(_ a: ContinuousClock.Instant?, _ b: ContinuousClock.Instant?) -> String {
        guard let a, let b else { return "-" }
        return "\(Int((b - a) / .milliseconds(1)))ms"
    }

    static func ms(int a: ContinuousClock.Instant?, _ b: ContinuousClock.Instant?) -> Int? {
        guard let a, let b else { return nil }
        return Int((b - a) / .milliseconds(1))
    }

    /// Copies this dictation's stage times into its history record.
    func fill(_ record: DictationRecord) -> DictationRecord {
        var r = record
        r.setupMs = Self.ms(int: press, ready)
        r.asrMs = Self.ms(int: release, asrDone)
        r.llmMs = Self.ms(int: refineStart, refineDone)
        r.pasteMs = Self.ms(int: pasteFrom, pasted)
        r.totalMs = Self.ms(int: release, pasted)
        r.replaceMs = Self.ms(int: refineDone, replaced)
        return r
    }

    func log(engine: String, partials: Int) {
        let line = "engine=\(engine) partials=\(partials) setup=\(Self.ms(press, ready)) asr=\(Self.ms(release, asrDone)) "
            + "llm=\(Self.ms(refineStart, refineDone)) paste=\(Self.ms(pasteFrom, pasted)) release→text=\(Self.ms(release, pasted)) "
            + "cleanup=\(Self.ms(pasted, injectDone)) replace=\(Self.ms(refineDone, replaced))"
        // Notice, not info: info lines live only in the process's memory buffer and vanish when
        // the app is restarted (every `make install`), so `log show --last 7d` showed almost nothing.
        // This line carries only numbers, never transcript text, so persisting it is safe.
        Log.app.notice("latency \(line, privacy: .public)")
    }
}
