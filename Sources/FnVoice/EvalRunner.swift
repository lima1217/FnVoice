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

        let settings = AppSettings()
        let config = LLMConfig.forEval(settings)
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
        var rewrite: [EvalRow] = []
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
                    await refine(&row, raw, app: nil, with: refiner, scope: scope)
                } catch {
                    row.note = "ASR error: \(error.localizedDescription)"
                }
                print("[\(c.id)] \(row.raw ?? "-") → \(row.refined ?? "-")")
                mixed.append(row)

            case .correct:
                var row = EvalRow(id: c.id, reference: c.reference, raw: c.reference, refined: nil)
                await refine(&row, c.reference, app: c.app, with: refiner, scope: scope)
                if row.llmMs == nil, row.refined != nil {
                    print("[\(c.id)] skipped by gate")
                } else if let out = row.refined {
                    print("[\(c.id)] \(out == c.reference ? "unchanged" : "CHANGED → \(out)")")
                }
                correct.append(row)

            case .cleanup:
                let input = c.input ?? c.reference
                var row = EvalRow(id: c.id, reference: c.reference, raw: input, refined: nil)
                await refine(&row, input, app: c.app, with: refiner, scope: scope)
                print("[\(c.id)] \(input) → \(row.refined ?? "-")")
                cleanup.append(row)
            
            case .rewrite:
                // No rewrite mode yet: these run through the same refinement as everything else,
                // so the section is a baseline for the fact check.
                let input = c.input ?? c.reference
                var row = EvalRow(id: c.id, reference: c.reference, raw: input, refined: nil)
                row.category = c.category
                await refine(&row, input, app: nil, with: refiner, scope: scope)
                if let out = row.refined {
                    row.facts = FactCheck.check(source: input, output: out, vocabulary: vocabulary, keep: c.keep ?? [], drop: c.drop ?? [])
                }
                print("[\(c.id)] \(row.facts?.summary ?? "-")")
                rewrite.append(row)
            }
        }

        let header = """
            Generated \(ISO8601DateFormatter().string(from: Date())) · language \(language.rawValue) · engine \(engine.displayName) · \
            speech \(speechOK ? "authorized" : "NOT authorized") · LLM \(refiner == nil ? "not configured" : "model \(config.model), gate \(scope.rawValue)")
            """
        let report = EvalReport.markdown(mixed: mixed, correct: correct, cleanup: cleanup, rewrite: rewrite, llmEnabled: refiner != nil, header: header)
        return writeReport(report, to: outPath)
    }

    /// Refines `input` into `row` the way live dictation would: skipped when the gate says so,
    /// timed when the LLM is called. Leaves `row.refined` nil when no LLM is configured.
    private static func refine(
        _ row: inout EvalRow, _ input: String, app: String?, with refiner: Refiner?, scope: RefinementScope
    ) async {
        guard let refiner else { return }
        guard RefinementGate.shouldRefine(input, scope: scope) else {
            row.refined = input
            row.note = "LLM skipped by gate"
            return
        }
        let started = ContinuousClock.now
        let outcome = await refiner.refine(input, app: app)
        row.llmMs = Int((ContinuousClock.now - started) / .milliseconds(1))
        row.refined = outcome.text
        row.note = outcome.evalNote
    }

    private static func transcribe(_ url: URL, language: DictationLanguage, vocabulary: [String], engine: RecognitionEngine) async throws -> String {
        if engine != .legacy, #available(macOS 26.0, *) {
            return try await AnalyzerCapture.transcribeFile(url, language: language, vocabulary: vocabulary, engine: engine)
        }
        return try await SpeechCapture.transcribeFile(url, language: language, vocabulary: vocabulary)
    }
}

/// Writes an eval report; the exit code for the run.
func writeReport(_ report: String, to path: String) -> Int32 {
    do {
        try report.write(toFile: path, atomically: true, encoding: .utf8)
        print("report written to \(path)")
        return 0
    } catch {
        print("cannot write report: \(error)")
        return 73
    }
}

extension LLMConfig {
    /// The app's LLM settings, each overridden by its FNVOICE_LLM_* variable when that is set and
    /// non-empty (`make eval` forwards them as empty strings when unset). The Keychain is read only
    /// when FNVOICE_LLM_API_KEY is missing.
    static func forEval(_ settings: AppSettings) -> LLMConfig {
        let env = ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty }
        return LLMConfig(
            baseURL: env["FNVOICE_LLM_BASE_URL"] ?? settings.llmBaseURL,
            apiKey: env["FNVOICE_LLM_API_KEY"] ?? Keychain.readAPIKey(),
            model: env["FNVOICE_LLM_MODEL"] ?? settings.llmModel
        )
    }
}

private extension RefineOutcome {
    /// Why the LLM answer wasn't used as is, with the answer itself when the guard intervened.
    var evalNote: String? {
        let parts = [fallbackReason, reverted > 0 ? "put back \(reverted)" : nil, rejected.map { "LLM: \($0)" }]
        let note = parts.compactMap { $0 }.joined(separator: " · ")
        return note.isEmpty ? nil : note
    }
}
