import Foundation
import FnVoiceCore

/// `FnVoice --eval-live [history.jsonl] --out report.md [--limit N] [--no-llm] [--gate all|englishOnly]`
///
/// Regression test on your own dictations: replays the recorded recognizer text through today's
/// corrections, gate and refinement, and scores it against the text you left in the field. Also
/// summarizes the recorded live latencies and refinement outcomes. No audio is involved, so this
/// needs no speech permission; it runs via `open` only so the app can read its Keychain API key.
@MainActor enum LiveEvalRunner {
    static func run(arguments args: [String]) async -> Int32 {
        let path = argumentValue("--eval-live", in: args).flatMap { $0.hasPrefix("--") ? nil : $0 }
            ?? AppController.historyURL.path
        let outPath = argumentValue("--out", in: args) ?? "Eval/report-live.md"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("no history at \(path): dictate with menu › 听写历史 › 保留历史 on")
            return 66
        }
        var records = DictationHistory.parse(text)
        if let limit = argumentValue("--limit", in: args).flatMap(Int.init), records.count > limit {
            records = Array(records.suffix(limit))
        }

        let settings = AppSettings()
        let config = LLMConfig.forEval(settings)
        let scope = argumentValue("--gate", in: args).flatMap(RefinementScope.init(rawValue:)) ?? settings.refinementScope
        let userVocabulary = AppController.userVocabulary()
        let corrections = ((try? String(contentsOf: AppController.correctionsURL, encoding: .utf8))
            .map(CorrectionStore.parse) ?? CorrectionStore())
            .aligned(with: Vocabulary.merged(user: userVocabulary))
        // Same client settings as live dictation (4 s timeout, hedge at 2 s), so timeouts are comparable.
        let refiner = !args.contains("--no-llm") && config.isConfigured
            ? Refiner(
                client: OpenAICompatibleClient(config: config),
                vocabulary: Vocabulary.merged(user: userVocabulary + corrections.vocabularyTerms()),
                corrections: corrections.hints()
            )
            : nil

        var rows: [LiveEval.Row] = []
        for (i, record) in records.enumerated() {
            var row = LiveEval.Row(record: record)
            if let refiner {
                // Mirrors AppController: learned replacements, then the gate, then the LLM.
                let input = corrections.apply(record.raw)
                if RefinementGate.shouldRefine(input, scope: scope) || corrections.mentionsKnownMistake(input) {
                    let started = ContinuousClock.now
                    let outcome = await refiner.refine(input, app: record.appName)
                    row.rerunMs = Int((ContinuousClock.now - started) / .milliseconds(1))
                    row.rerun = TextFormatter.format(outcome.text)
                    row.rerunLLM = outcome.status
                    row.rerunReason = outcome.fallbackReason
                } else {
                    row.rerun = TextFormatter.format(input)
                    row.rerunLLM = .skipped
                }
                print("[\(i + 1)/\(records.count)] \(row.rerunLLM!.rawValue) \(row.rerunMs.map { "\($0)ms" } ?? "")")
            }
            rows.append(row)
        }

        let header = "Generated \(ISO8601DateFormatter().string(from: Date())) from `\(path)` · "
            + (refiner == nil
                ? "re-run off (\(config.isConfigured ? "--no-llm" : "LLM not configured"))"
                : "re-run with model \(config.model), gate \(scope.rawValue), \(corrections.entries.count) learned corrections")
        let report = LiveEval.markdown(rows: rows, header: header)
        return writeReport(report, to: outPath)
    }
}
