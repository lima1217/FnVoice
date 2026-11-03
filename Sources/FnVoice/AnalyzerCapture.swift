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

    static func make(_ engine: RecognitionEngine, locale: Locale) -> AnalyzerModule {
        switch engine {
        case .dictationTranscriber:
            let t = DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: []
            )
            return AnalyzerModule(module: t, results: flatten(t.results) { (String($0.text.characters), $0.isFinal) })
        default:
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
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

/// Converts mic buffers to the analyzer's format on the audio thread and feeds the input stream.
@available(macOS 26.0, *)
final class AnalyzerAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    let levels = LevelBox()

    func configure(input: AVAudioFormat, target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation?) {
        lock.withLock {
            self.target = target
            self.converter = input == target ? nil : AVAudioConverter(from: input, to: target)
            self.continuation = continuation
        }
    }

    func detach() {
        lock.withLock { continuation = nil }
        levels.set(0)
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0] {
            levels.set(LevelMeter.level(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
        lock.withLock {
            guard let continuation, let target else { return }
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
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
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var transcript = AnalyzerModule.Transcript()
    private var lastError: String?
    private var generation = 0

    init(engine: RecognitionEngine) {
        engineKind = engine
    }

    func start(language: DictationLanguage, vocabulary: [String]) async throws {
        cancel()
        generation += 1
        let gen = generation
        transcript = .init()
        lastError = nil

        guard let locale = await AnalyzerModule.supportedLocale(engineKind, for: language) else {
            throw CaptureError.unsupportedLanguage(language.rawValue)
        }
        let module = AnalyzerModule.make(engineKind, locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) {
            // First use of this language: download in the background; the caller falls back for now.
            Task.detached { try? await request.downloadAndInstall() }
            throw CaptureError.modelDownloading(language.rawValue)
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.module]) else {
            throw CaptureError.engine("no compatible audio format")
        }
        let analyzer = SpeechAnalyzer(modules: [module.module])
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        try? await analyzer.setContext(context)
        guard gen == generation else { return } // cancelled while setting up

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.input = continuation
        self.targetFormat = target
        resultsTask = Task { [weak self] in
            do {
                for try await (text, isFinal) in module.results {
                    guard let self, gen == self.generation else { return }
                    self.transcript.apply(text, isFinal: isFinal)
                    self.onPartial?(self.transcript.text)
                }
            } catch is CancellationError {
            } catch {
                guard let self, gen == self.generation else { return }
                Log.asr.notice("analyzer results ended with error: \(error.localizedDescription, privacy: .public)")
                self.lastError = "Recognition failed: \(error.localizedDescription)"
            }
        }
        do {
            try startAudio()
            try await analyzer.start(inputSequence: stream)
        } catch {
            cancel()
            throw error
        }
        Log.asr.info("analyzer started engine=\(self.engineKind.rawValue, privacy: .public) locale=\(locale.identifier, privacy: .public)")
    }

    func finish() async -> (text: String, error: String?) {
        let gen = generation
        try? await Task.sleep(for: .milliseconds(250)) // don't clip the last syllable
        guard gen == generation else { return ("", nil) }
        stopAudio()
        input?.finish()
        input = nil
        if let analyzer {
            // Bound the wait: if finalization stalls, cancel, which ends the results stream.
            let watchdog = Task {
                try await Task.sleep(for: .milliseconds(1500))
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
        }
        let text = transcript.text
        cleanup()
        return (text, text.isEmpty ? lastError : nil)
    }

    func cancel() {
        generation += 1
        stopAudio()
        input?.finish()
        resultsTask?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        cleanup()
    }

    private func cleanup() {
        input = nil
        analyzer = nil
        resultsTask = nil
        sink.detach()
    }

    private func startAudio() throws {
        guard let target = targetFormat else { return }
        let node = audio.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        sink.configure(input: format, target: target, continuation: input)
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

    /// Input device or format changed (AirPods → HFP): re-tap with a converter for the new format.
    private func rebuildAudio() {
        guard input != nil else { return }
        Log.audio.notice("audio configuration changed; rebuilding analyzer input")
        stopAudio()
        audio = AVAudioEngine()
        do {
            try startAudio()
        } catch {
            Log.audio.error("rebuild failed: \(String(describing: error), privacy: .public)")
            input?.finish()
        }
    }

    /// Same engine settings as live dictation, on a file (used by --eval).
    nonisolated static func transcribeFile(_ url: URL, language: DictationLanguage, vocabulary: [String], engine: RecognitionEngine) async throws -> String {
        guard let locale = await AnalyzerModule.supportedLocale(engine, for: language) else {
            throw CaptureError.unsupportedLanguage(language.rawValue)
        }
        let module = AnalyzerModule.make(engine, locale: locale)
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
