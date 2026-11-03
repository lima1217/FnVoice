import AVFoundation
import FnVoiceCore
import Speech

/// The live-dictation surface shared by the legacy SFSpeechRecognizer engine and the
/// SpeechAnalyzer engines, so AppController doesn't care which one is running.
@MainActor protocol LiveTranscriber: AnyObject {
    var levels: LevelBox { get }
    var onPartial: ((String) -> Void)? { get set }
    var isOnDevice: Bool { get }
    func start(language: DictationLanguage, vocabulary: [String]) async throws
    /// Stops capture after a short tail and returns the final text, or the error that explains an empty result.
    func finish() async -> (text: String, error: String?)
    func cancel()
}

extension SpeechCapture: LiveTranscriber {
    func finish() async -> (text: String, error: String?) {
        await finish(trailing: .milliseconds(250), finalTimeout: .milliseconds(1500))
    }
}

/// One SpeechAnalyzer module plus its results flattened to (text, isFinal).
@available(macOS 26.0, *)
struct AnalyzerModule {
    let module: any SpeechModule
    let results: AsyncThrowingStream<(text: String, isFinal: Bool), Error>

    /// - Parameter fast: SpeechTranscriber fast mode (live partials, lower accuracy). Menu › Show Live Text.
    static func make(_ engine: RecognitionEngine, locale: Locale, fast: Bool) -> AnalyzerModule {
        switch engine {
        case .dictationTranscriber:
            let t = DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []
            )
            return AnalyzerModule(module: t, results: flatten(t.results) { (String($0.text.characters), $0.isFinal) })
        default:
            // .fastResults makes partials stream while you speak (first text ~1.2 s in). Without it,
            // SpeechTranscriber sends nothing until Fn is released, so the capsule stays empty.
            // It costs accuracy (CER after refinement 5.9% → 9.0%); see README › Recognition engines.
            // A second, accurate analyzer alongside a fast one was tried and is unreliable: the two
            // share Apple's speech service and the accurate one returned a single character.
            let reporting: Set<SpeechTranscriber.ReportingOption> = fast ? [.volatileResults, .fastResults] : [.volatileResults]
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reporting, attributeOptions: [])
            return AnalyzerModule(module: t, results: flatten(t.results) { (String($0.text.characters), $0.isFinal) })
        }
    }

    static func supportedLocale(_ engine: RecognitionEngine, for language: DictationLanguage) async -> Locale? {
        let wanted = Locale(identifier: language.rawValue)
        switch engine {
        case .dictationTranscriber: return await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        default: return await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        }
    }

    private static func flatten<S: AsyncSequence & Sendable>(
        _ seq: S, _ map: @escaping @Sendable (S.Element) -> (String, Bool)
    ) -> AsyncThrowingStream<(text: String, isFinal: Bool), Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await r in seq {
                        let (text, isFinal) = map(r)
                        cont.yield((text, isFinal))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Accumulates finalized segments; the trailing volatile segment is replaced as it updates.
    struct Transcript {
        var finalized = ""
        var volatile = ""
        var text: String { finalized + volatile }

        mutating func apply(_ text: String, isFinal: Bool) {
            if isFinal {
                finalized += text
                volatile = ""
            } else {
                volatile = text
            }
        }
    }
}

/// One recognition pass through SpeechAnalyzer: set up, fed audio by its owner (mic or file), finished.
/// Shared by live dictation and `--latency-bench`, so the benchmark measures the shipped code path.
@available(macOS 26.0, *)
@MainActor final class AnalyzerSession {
    /// How long the model stays loaded after a session. `.processLifetime` keeps the menu-bar app
    /// ready for the next Fn press; chosen from `--latency-bench` (see README › Latency).
    static var retention: SpeechAnalyzer.Options.ModelRetention = .processLifetime

    private struct Setup {
        let locale: Locale
        let format: AVAudioFormat
    }

    /// Locale resolution, asset check and audio format cost several awaits; cache them per engine+language.
    private static var setupCache: [String: Setup] = [:]

    let format: AVAudioFormat
    let input: AsyncStream<AnalyzerInput>.Continuation
    var onUpdate: ((String) -> Void)?
    private(set) var error: String?
    private let analyzer: SpeechAnalyzer
    private var transcript = AnalyzerModule.Transcript()
    private var resultsTask: Task<Void, Never>?
    private var finished = false

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.format = format
        self.input = input
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// The analyzer input format for this engine+language if already known (no awaits).
    static func cachedFormat(_ engine: RecognitionEngine, _ language: DictationLanguage) -> AVAudioFormat? {
        setupCache["\(engine.rawValue)|\(language.rawValue)"]?.format
    }

    private static func setup(_ engine: RecognitionEngine, _ language: DictationLanguage, module: (Locale) -> AnalyzerModule) async throws -> (Setup, AnalyzerModule) {
        let key = "\(engine.rawValue)|\(language.rawValue)"
        if let cached = setupCache[key] { return (cached, module(cached.locale)) }
        guard let locale = await AnalyzerModule.supportedLocale(engine, for: language) else {
            throw CaptureError.unsupportedLanguage(language.rawValue)
        }
        let m = module(locale)
        // assetInstallationRequest returns a request even for installed models, so ask for status instead.
        if await AssetInventory.status(forModules: [m.module]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [m.module]) {
                Task.detached { try? await request.downloadAndInstall() }
            }
            throw CaptureError.modelDownloading(language.rawValue)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m.module]) else {
            throw CaptureError.engine("no compatible audio format")
        }
        let setup = Setup(locale: locale, format: format)
        setupCache[key] = setup
        return (setup, m)
    }

    static func prepare(engine: RecognitionEngine, language: DictationLanguage, vocabulary: [String], fast: Bool) async throws -> AnalyzerSession {
        let (setup, module) = try await setup(engine, language) { AnalyzerModule.make(engine, locale: $0, fast: fast) }
        let analyzer = SpeechAnalyzer(modules: [module.module], options: .init(priority: .userInitiated, modelRetention: retention))
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        try? await analyzer.setContext(context)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let session = AnalyzerSession(analyzer: analyzer, format: setup.format, input: continuation)
        session.resultsTask = Task { [weak session] in
            do {
                for try await (text, isFinal) in module.results {
                    guard let session else { return }
                    session.transcript.apply(text, isFinal: isFinal)
                    session.onUpdate?(session.transcript.text)
                }
            } catch is CancellationError {
            } catch {
                Log.asr.notice("analyzer results ended with error: \(error.localizedDescription, privacy: .public)")
                session?.error = "Recognition failed: \(error.localizedDescription)"
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            throw CaptureError.engine("analyzer start: \(error)")
        }
        return session
    }

    /// Loads the model ahead of the first Fn press so that press doesn't pay the load time.
    static func prewarm(engine: RecognitionEngine, language: DictationLanguage, fast: Bool) async {
        do {
            let (setup, module) = try await setup(engine, language) { AnalyzerModule.make(engine, locale: $0, fast: fast) }
            let analyzer = SpeechAnalyzer(modules: [module.module], options: .init(priority: .utility, modelRetention: retention))
            try await analyzer.prepareToAnalyze(in: setup.format)
            await analyzer.cancelAndFinishNow()
            Log.asr.info("prewarmed \(engine.rawValue, privacy: .public)/\(language.rawValue, privacy: .public)")
        } catch {
            Log.asr.notice("prewarm skipped: \(String(describing: error), privacy: .public)")
        }
    }

    /// Ends input and waits (bounded) for the final text.
    func finish(timeout: Duration = .milliseconds(1500)) async -> String {
        guard !finished else { return transcript.text }
        finished = true
        input.finish()
        let analyzer = self.analyzer
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            Log.asr.notice("analyzer finalization timed out; using results so far")
            await analyzer.cancelAndFinishNow()
        }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.asr.notice("analyzer finalize failed: \(error.localizedDescription, privacy: .public)")
        }
        await resultsTask?.value
        watchdog.cancel()
        return transcript.text
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        input.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Mic buffers → analyzer input, on the audio thread. Until a session is attached, buffers are
/// held (copied) so speech in the first moments after Fn-down isn't lost while the model loads.
@available(macOS 26.0, *)
final class AnalyzerAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pending: [AVAudioPCMBuffer] = []
    private var capturing = false
    /// ~10 s of 1024-frame buffers at 48 kHz.
    private let maxPending = 500
    let levels = LevelBox()

    func beginCapture() {
        lock.withLock {
            pending = []
            capturing = true
            continuation = nil
            target = nil
            converter = nil
        }
    }

    func attach(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.withLock {
            self.target = target
            self.continuation = continuation
            for buffer in pending { convertAndYield(buffer) }
            pending = []
        }
    }

    func detach() {
        lock.withLock {
            capturing = false
            continuation = nil
            pending = []
        }
        levels.set(0)
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0] {
            levels.set(LevelMeter.level(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
        lock.withLock {
            if continuation != nil {
                convertAndYield(buffer)
            } else if capturing, pending.count < maxPending, let copy = Self.copy(buffer) {
                pending.append(copy) // the tap may reuse its buffer
            }
        }
    }

    /// Caller holds the lock.
    private func convertAndYield(_ buffer: AVAudioPCMBuffer) {
        guard let continuation, let target else { return }
        if buffer.format == target {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target) // also after an audio route change
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let once = OnceFlag() // hand the converter this one buffer, then report "no more for now"
        // The input block runs synchronously inside convert(), on this thread.
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard once.claim() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return source
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let dst = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samples = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        for c in 0..<channels { dst[c].update(from: src[c], count: samples) }
        return copy
    }

    static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, sink: AnalyzerAudioSink) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            sink.consume(buffer)
        }
    }
}

/// Live dictation through SpeechAnalyzer (macOS 26). Always on-device; no ~1 minute server cap.
@available(macOS 26.0, *)
@MainActor final class AnalyzerCapture: LiveTranscriber {
    let engineKind: RecognitionEngine
    let sink = AnalyzerAudioSink()
    var levels: LevelBox { sink.levels }
    var onPartial: ((String) -> Void)?
    let isOnDevice = true

    private var audio = AVAudioEngine()
    private var session: AnalyzerSession?
    private var configObserver: NSObjectProtocol?
    private var generation = 0

    /// Read at each Fn press, so toggling the menu item applies to the next dictation.
    private let liveText: () -> Bool

    init(engine: RecognitionEngine, liveText: @escaping () -> Bool) {
        engineKind = engine
        self.liveText = liveText
    }

    func start(language: DictationLanguage, vocabulary: [String]) async throws {
        cancel()
        generation += 1
        let gen = generation
        // Mic first: whatever is said while the analyzer sets up is buffered, not lost.
        sink.beginCapture()
        try startAudio()
        do {
            let session = try await AnalyzerSession.prepare(engine: engineKind, language: language, vocabulary: vocabulary, fast: liveText())
            guard gen == generation else {
                session.cancel()
                return
            }
            session.onUpdate = { [weak self] text in self?.onPartial?(text) }
            self.session = session
            sink.attach(target: session.format, continuation: session.input)
        } catch {
            stopAudio()
            sink.detach()
            throw error
        }
    }

    func finish() async -> (text: String, error: String?) {
        let gen = generation
        try? await Task.sleep(for: .milliseconds(250)) // don't clip the last syllable
        guard gen == generation, let session else { return ("", nil) }
        stopAudio()
        sink.detach()
        let text = await session.finish()
        self.session = nil
        return (text, text.isEmpty ? session.error : nil)
    }

    func cancel() {
        generation += 1
        stopAudio()
        sink.detach()
        session?.cancel()
        session = nil
    }

    private func startAudio() throws {
        let node = audio.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        AnalyzerAudioSink.installTap(on: node, format: format, sink: sink)
        audio.prepare()
        do {
            try audio.start()
        } catch {
            node.removeTap(onBus: 0)
            throw CaptureError.engine(error.localizedDescription)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
        ) { [self] _ in
            MainActor.assumeIsolated { self.rebuildAudio() }
        }
    }

    private func stopAudio() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
    }

    /// Input device or format changed (AirPods → HFP): re-tap; the sink rebuilds its converter.
    private func rebuildAudio() {
        guard session != nil else { return }
        Log.audio.notice("audio configuration changed; rebuilding analyzer input")
        stopAudio()
        audio = AVAudioEngine()
        do {
            try startAudio()
        } catch {
            Log.audio.error("rebuild failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Same engine settings as live dictation, on a file (used by --eval).
    nonisolated static func transcribeFile(_ url: URL, language: DictationLanguage, vocabulary: [String], engine: RecognitionEngine, fast: Bool) async throws -> String {
        guard let locale = await AnalyzerModule.supportedLocale(engine, for: language) else {
            throw CaptureError.unsupportedLanguage(language.rawValue)
        }
        let module = AnalyzerModule.make(engine, locale: locale, fast: fast)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [module.module])
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        try await analyzer.setContext(context)
        let collector = Task {
            var transcript = AnalyzerModule.Transcript()
            for try await (text, isFinal) in module.results { transcript.apply(text, isFinal: isFinal) }
            return transcript.text
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value
    }
}
