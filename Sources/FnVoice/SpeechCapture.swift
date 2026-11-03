import AVFoundation
import FnVoiceCore
import Speech

enum CaptureError: Error {
    case unsupportedLanguage(String)
    case recognizerUnavailable
    case noInputDevice
    case engine(String)
    case modelDownloading(String)

    var userMessage: String {
        switch self {
        case .unsupportedLanguage(let id): "Speech recognition doesn't support \(id)"
        case .recognizerUnavailable: "Speech recognizer unavailable (offline?)"
        case .noInputDevice: "No microphone input"
        case .engine(let msg): "Audio error: \(msg)"
        case .modelDownloading(let id): "Downloading the \(id) speech model…"
        }
    }
}

/// Latest normalized loudness, written on the audio thread, read by the display link.
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    func set(_ v: Float) { lock.withLock { value = v } }
    func get() -> Float { lock.withLock { value } }
}

/// Everything the realtime audio tap touches. Kept off the main actor: the tap block runs on
/// an audio thread, and a main-actor-isolated closure there traps at runtime under Swift 6.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    let levels = LevelBox()

    func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = r } }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
        guard let channel = buffer.floatChannelData?[0] else { return }
        levels.set(LevelMeter.level(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }

    static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, sink: AudioSink) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            sink.consume(buffer)
        }
    }
}

@MainActor final class SpeechCapture {
    let sink = AudioSink()
    var levels: LevelBox { sink.levels }
    var onPartial: ((String) -> Void)?

    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var configObserver: NSObjectProtocol?
    private var generation = 0
    private var latestText = ""
    /// A recognition error worth telling the user about (not "no speech detected").
    private var lastError: String?
    private var finished = false
    private var finalWaiter: CheckedContinuation<String, Never>?
    private(set) var isOnDevice = false
    private(set) var partialsDuringCapture = 0
    private var capturing = false

    func start(language: DictationLanguage, vocabulary: [String]) throws {
        cancel()
        generation += 1
        let gen = generation
        latestText = ""
        lastError = nil
        finished = false
        partialsDuringCapture = 0
        capturing = true

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)) else {
            throw CaptureError.unsupportedLanguage(language.rawValue)
        }
        guard recognizer.isAvailable else { throw CaptureError.recognizerUnavailable }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = vocabulary
        isOnDevice = recognizer.supportsOnDeviceRecognition
        req.requiresOnDeviceRecognition = isOnDevice
        request = req
        sink.setRequest(req)

        task = Self.startTask(recognizer: recognizer, request: req) { [self] text, isFinal, error in
            self.handle(gen: gen, text: text, isFinal: isFinal, error: error)
        }
        Log.asr.info("recognition started lang=\(language.rawValue, privacy: .public) onDevice=\(self.isOnDevice)")

        do {
            try startEngine()
        } catch {
            cancel()
            throw error
        }
    }

    /// Keeps capturing for `trailing` so the last syllable isn't clipped, then waits for the
    /// final result (bounded by `finalTimeout`, falling back to the latest partial).
    func finish(trailing: Duration = .milliseconds(250), finalTimeout: Duration = .milliseconds(1500)) async -> (text: String, error: String?) {
        let gen = generation
        capturing = false
        try? await Task.sleep(for: trailing)
        guard gen == generation else { return ("", nil) }
        stopEngine()
        request?.endAudio()
        let text: String
        if finished {
            text = latestText
        } else {
            text = await withCheckedContinuation { cont in
                finalWaiter = cont
                Task { @MainActor in
                    try? await Task.sleep(for: finalTimeout)
                    if gen == self.generation, self.finalWaiter != nil {
                        Log.asr.notice("final result timed out; using latest partial")
                        self.resumeWaiter()
                    }
                }
            }
        }
        cleanup()
        return (text, text.isEmpty ? lastError : nil)
    }

    func cancel() {
        generation += 1
        stopEngine()
        task?.cancel()
        resumeWaiter()
        cleanup()
    }

    private func cleanup() {
        sink.setRequest(nil)
        request = nil
        task = nil
        sink.levels.set(0)
    }

    private func handle(gen: Int, text: String?, isFinal: Bool, error: RecognitionFailure?) {
        guard gen == generation else { return }
        if let text, !text.isEmpty {
            if capturing { partialsDuringCapture += 1 }
            latestText = text
            onPartial?(text)
        }
        if let error {
            // "No speech detected" after endAudio and the server's ~1 min cap land here; keep what we have.
            Log.asr.notice("recognition ended with error \(error.domain, privacy: .public)#\(error.code): \(error.message, privacy: .public)")
            if !error.isBenign { lastError = error.userMessage }
            finished = true
            resumeWaiter()
        } else if isFinal {
            finished = true
            resumeWaiter()
        }
    }

    private func resumeWaiter() {
        if let w = finalWaiter {
            finalWaiter = nil
            w.resume(returning: latestText)
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        AudioSink.installTap(on: input, format: format, sink: sink)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engine(error.localizedDescription)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [self] _ in
            MainActor.assumeIsolated { self.rebuildEngine() }
        }
        Log.audio.info("engine started \(format.sampleRate, privacy: .public)Hz ch=\(format.channelCount, privacy: .public)")
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// The input device or its format changed (AirPods switching to HFP, mic unplugged).
    /// Re-tapping with the old format would crash, so rebuild with the new one and keep the
    /// same recognition request.
    private func rebuildEngine() {
        guard request != nil else { return }
        Log.audio.notice("audio configuration changed; rebuilding engine")
        stopEngine()
        engine = AVAudioEngine()
        do {
            try startEngine()
        } catch {
            Log.audio.error("rebuild failed: \(String(describing: error), privacy: .public)")
            request?.endAudio()
        }
    }

    // MARK: - Nonisolated helpers (callbacks arrive on arbitrary queues)

    private nonisolated static func startTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechRecognitionRequest,
        onUpdate: @escaping @MainActor @Sendable (String?, Bool, RecognitionFailure?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { @Sendable result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { RecognitionFailure($0 as NSError) }
            Task { @MainActor in onUpdate(text, isFinal, failure) }
        }
    }

    /// Transcribes an audio file with the same recognizer settings as live dictation (used by --eval).
    nonisolated static func transcribeFile(_ url: URL, language: DictationLanguage, vocabulary: [String]) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)) else {
            throw CaptureError.unsupportedLanguage(language.rawValue)
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = vocabulary
        req.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            recognizer.recognitionTask(with: req) { @Sendable result, error in
                if let result, result.isFinal, once.claim() {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error, once.claim() {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

struct RecognitionFailure: Sendable {
    let domain: String
    let code: Int
    let message: String

    init(_ e: NSError) {
        domain = e.domain
        code = e.code
        message = e.localizedDescription
    }

    /// kAFAssistantErrorDomain 1110 = no speech detected; 203/216/301 = cancelled/ended by us.
    var isBenign: Bool {
        domain == "kAFAssistantErrorDomain" && [203, 216, 301, 1110].contains(code)
    }

    var userMessage: String {
        if message.localizedCaseInsensitiveContains("dictation") && message.localizedCaseInsensitiveContains("disabled") {
            return "Turn on Dictation in System Settings › Keyboard"
        }
        return "Recognition failed: \(message)"
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
