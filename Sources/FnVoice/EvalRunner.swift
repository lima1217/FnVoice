import Foundation
import FnVoiceCore
import Speech

/// `FnVoice --eval <corpus.jsonl> --out <report.md> [--lang zh-CN]`
///
/// Runs the real recognizer (same settings as live dictation) on each corpus audio file, then the
/// real refinement pipeline, and writes a CER / false-correction report. LLM config comes from
/// FNVOICE_LLM_BASE_URL / FNVOICE_LLM_API_KEY / FNVOICE_LLM_MODEL, else from the app's settings.
@MainActor enum EvalRunner {
    static func run(arguments args: [String]) async -> Int32 {
        guard let corpusPath = argumentValue("--eval", in: args) else {
            print("usage: FnVoice --eval corpus.jsonl --out report.md [--lang zh-CN] [--engine speechTranscriber|dictationTranscriber|legacy]")
            return 64
        }
        let outPath = argumentValue("--out", in: args) ?? "Eval/report.md"
        let language = argumentValue("--lang", in: args).flatMap(DictationLanguage.init(rawValue:)) ?? .simplifiedChinese
        let corpusURL = URL(fileURLWithPath: corpusPath)
        let engine = RecognitionEngine.resolve(
            stored: argumentValue("--engine", in: args).flatMap(RecognitionEngine.init(rawValue:)) ?? AppSettings().recognitionEngine,
            analyzerAvailable: AppController.analyzerAvailable
        )

        let cases: [EvalCase]
        do {
            cases = try EvalCase.loadJSONL(String(contentsOf: corpusURL, encoding: .utf8))
        } catch {
            print("cannot read corpus: \(error)")
            return 66
        }

        // `make eval` always forwards these, as empty strings when unset; empty means "use app settings".
        let env = ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty }
        let settings = AppSettings()
        let config = LLMConfig(
            baseURL: env["FNVOICE_LLM_BASE_URL"] ?? settings.llmBaseURL,
            apiKey: env["FNVOICE_LLM_API_KEY"] ?? Keychain.readAPIKey(),
            model: env["FNVOICE_LLM_MODEL"] ?? settings.llmModel
        )
        let userVocabulary = (try? String(contentsOf: AppController.vocabularyURL, encoding: .utf8)).map(Vocabulary.parse) ?? []
        let vocabulary = Vocabulary.merged(user: userVocabulary)
        let scope = argumentValue("--gate", in: args).flatMap(RefinementScope.init(rawValue:)) ?? settings.refinementScope
        let refiner = config.isConfigured
            ? Refiner(client: OpenAICompatibleClient(config: config, timeout: .seconds(15)), vocabulary: vocabulary)
            : nil

        var speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized
        if !speechOK && SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speechOK = await Permissions.requestSpeech() == .authorized
        }

        var mixed: [EvalRow] = []
        var correct: [EvalRow] = []
        var cleanup: [EvalRow] = []
        for c in cases {
            switch c.kind {
            case .mixed:
                var row = EvalRow(id: c.id, reference: c.reference, raw: nil, refined: nil)
                guard speechOK else {
                    row.note = "speech recognition not authorized"
                    mixed.append(row)
                    continue
                }
                guard let audio = c.audio else {
                    row.note = "no audio"
                    mixed.append(row)
                    continue
                }
                let url = corpusURL.deletingLastPathComponent().appendingPathComponent(audio)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    row.note = "missing \(audio) (run make eval-audio)"
                    mixed.append(row)
                    continue
                }
                do {
                    let raw = try await Self.transcribe(url, language: language, vocabulary: vocabulary, engine: engine)
                    row.raw = raw
                    if refiner != nil && !RefinementGate.shouldRefine(raw, scope: scope) {
                        row.refined = raw
                        row.note = "LLM skipped (no English)"
                    } else if let refiner {
                        let started = ContinuousClock.now
                        let outcome = await refiner.refine(raw)
                        row.llmMs = Int((ContinuousClock.now - started) / .milliseconds(1))
                        row.refined = outcome.text
                        row.note = outcome.fallbackReason
                    }
                } catch {
                    row.note = "ASR error: \(error.localizedDescription)"
                }
                print("[\(c.id)] \(row.raw ?? "-") → \(row.refined ?? "-")")
                mixed.append(row)

            case .correct:
                var row = EvalRow(id: c.id, reference: c.reference, raw: c.reference, refined: nil)
                if refiner != nil && !RefinementGate.shouldRefine(c.reference, scope: scope) {
                    row.refined = c.reference
                    row.note = "LLM skipped (no English)"
                    print("[\(c.id)] skipped by gate")
                } else if let refiner {
                    let started = ContinuousClock.now
                    let outcome = await refiner.refine(c.reference)
                    row.llmMs = Int((ContinuousClock.now - started) / .milliseconds(1))
                    row.refined = outcome.text
                    row.note = outcome.fallbackReason
                    print("[\(c.id)] \(outcome.text == c.reference ? "unchanged" : "CHANGED → \(outcome.text)")")
                }
                correct.append(row)

            case .cleanup:
                let input = c.input ?? c.reference
                var row = EvalRow(id: c.id, reference: c.reference, raw: input, refined: nil)
                if refiner != nil && !RefinementGate.shouldRefine(input, scope: scope) {
                    row.refined = input
                    row.note = "LLM skipped by gate"
                } else if let refiner {
                    let started = ContinuousClock.now
                    let outcome = await refiner.refine(input)
                    row.llmMs = Int((ContinuousClock.now - started) / .milliseconds(1))
                    row.refined = outcome.text
                    row.note = outcome.fallbackReason
                }
                print("[\(c.id)] \(input) → \(row.refined ?? "-")")
                cleanup.append(row)
            }
        }

        let header = """
            Generated \(ISO8601DateFormatter().string(from: Date())) · language \(language.rawValue) · engine \(engine.displayName) · \
            speech \(speechOK ? "authorized" : "NOT authorized") · LLM \(refiner == nil ? "not configured" : "model \(config.model), gate \(scope.rawValue)")
            """
        let report = EvalReport.markdown(mixed: mixed, correct: correct, cleanup: cleanup, llmEnabled: refiner != nil, header: header)
        do {
            try report.write(toFile: outPath, atomically: true, encoding: .utf8)
            print("report written to \(outPath)")
            return 0
        } catch {
            print("cannot write report: \(error)")
            return 73
        }
    }

    private static func transcribe(_ url: URL, language: DictationLanguage, vocabulary: [String], engine: RecognitionEngine) async throws -> String {
        if engine != .legacy, #available(macOS 26.0, *) {
            return try await AnalyzerCapture.transcribeFile(url, language: language, vocabulary: vocabulary, engine: engine)
        }
        return try await SpeechCapture.transcribeFile(url, language: language, vocabulary: vocabulary)
    }
}
