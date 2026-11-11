import Foundation
import Testing
@testable import FnVoiceCore

@Suite struct MetricsTests {
    @Test func levenshtein() {
        #expect(Levenshtein.distance(Array("kitten"), Array("sitting")) == 3)
        #expect(Levenshtein.distance(Array(""), Array("abc")) == 3)
        #expect(Levenshtein.distance(Array("配森"), Array("配森")) == 0)
    }

    @Test func cerIgnoresPunctuationSpacingAndCase() {
        #expect(ErrorRate.cer(reference: "我在用 Python。", hypothesis: "我在用python") == 0)
        #expect(ErrorRate.cer(reference: "我在用Python", hypothesis: "我在用配森") > 0.5)
        #expect(ErrorRate.cer(reference: "", hypothesis: "") == 0)
    }

    @Test func loadsCorpusSkippingCommentsAndBlanks() throws {
        let text = """
        // comment
        {"id":"m1","kind":"mixed","reference":"我在用Python","audio":"audio/m1.aiff"}

        {"id":"c1","kind":"correct","reference":"今天天气不错"}
        """
        let cases = try EvalCase.loadJSONL(text)
        #expect(cases == [
            EvalCase(id: "m1", kind: .mixed, reference: "我在用Python", audio: "audio/m1.aiff"),
            EvalCase(id: "c1", kind: .correct, reference: "今天天气不错"),
        ])
    }

    @Test func shippedCorpusIsValidAndBigEnough() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Eval/corpus.jsonl")
        let cases = try EvalCase.loadJSONL(String(contentsOf: url, encoding: .utf8))
        #expect(cases.filter { $0.kind == .mixed }.count >= 40)
        #expect(cases.filter { $0.kind == .correct }.count >= 20)
        #expect(cases.filter { $0.kind == .cleanup }.allSatisfy { $0.input != nil })
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(cases.filter { $0.kind == .mixed }.allSatisfy { $0.audio != nil })
    }

    @Test func reportComputesFalseCorrectionRate() {
        let mixed = [EvalRow(id: "m1", reference: "我用Python", raw: "我用配森", refined: "我用Python")]
        let correct = [
            EvalRow(id: "c1", reference: "好的", raw: "好的", refined: "好的"),
            EvalRow(id: "c2", reference: "没问题", raw: "没问题", refined: "没有问题"),
            // Punctuation fixes are part of the cleanup, not a false correction.
            EvalRow(id: "c3", reference: "好吧", raw: "好吧", refined: "好吧。"),
        ]
        let md = EvalReport.markdown(mixed: mixed, correct: correct, llmEnabled: true, header: "h")
        #expect(md.contains("False-correction rate: **33.3%** (1/3)"))
        #expect(md.contains("| zh + English terms | 1 | 75.0% | 0.0% |"))
    }

    @Test func reportScoresCleanupIgnoringPunctuation() {
        let cleanup = [
            EvalRow(id: "k1", reference: "周四开会。", raw: "周三不对周四开会", refined: "周四开会"),
            EvalRow(id: "k2", reference: "我觉得可以。", raw: "嗯我觉得可以", refined: "嗯我觉得可以"),
        ]
        let md = EvalReport.markdown(mixed: [], correct: [], cleanup: cleanup, llmEnabled: true, header: "h")
        #expect(md.contains("Matched: **1/2**"))
        #expect(md.contains("| k2 | 嗯我觉得可以 | 我觉得可以。 | 嗯我觉得可以 | MISS |"))
    }
}

extension MetricsTests {
    @Test func reportDoesNotClaimZeroCERWhenNothingWasTranscribed() {
        let mixed = [EvalRow(id: "m1", reference: "x", raw: nil, refined: nil, note: "ASR error")]
        let md = EvalReport.markdown(mixed: mixed, correct: [], llmEnabled: false, header: "h")
        #expect(md.contains("n/a (nothing transcribed"))
        #expect(!md.contains("| mean CER, raw ASR | 0.0% |"))
    }

    @Test func reportScoresRewritesByFactsPerCategory() {
        var kept = EvalRow(id: "r1", reference: "-", raw: "周三开会", refined: "周三开会。")
        kept.category = "numbers"
        kept.facts = FactCheck.check(source: "周三开会", output: "周三开会。")
        var lost = EvalRow(id: "r2", reference: "-", raw: "周三开会", refined: "开会。", note: "slow")
        lost.category = "numbers"
        lost.facts = FactCheck.check(source: "周三开会", output: "开会。")
        var other = EvalRow(id: "r3", reference: "-", raw: "好", refined: "好")
        other.category = "verbose"
        other.facts = FactCheck.check(source: "好", output: "好")
        let md = EvalReport.markdown(mixed: [], correct: [], rewrite: [kept, lost, other], llmEnabled: true, header: "h")
        #expect(md.contains("Facts preserved: **2/3**"))
        #expect(md.contains("| numbers | 1/2 |\n| verbose | 1/1 |"))
        #expect(md.contains("| r2 | numbers | 周三开会 | 开会。 | FAIL · missing: 周三 | slow |"))
    }

    @Test func reportSummarizesLLMLatencyAgainstTheLiveTimeout() {
        let rows = [100, 300, 5000, 200].enumerated().map { i, ms in
            var r = EvalRow(id: "c\(i)", reference: "好", raw: "好", refined: "好")
            r.llmMs = ms
            return r
        }
        let md = EvalReport.markdown(mixed: [], correct: rows, llmEnabled: true, header: "h", liveTimeoutMs: 4000)
        #expect(md.contains("LLM latency over 4 calls: median 300 ms, p90 5000 ms, max 5000 ms; 1 over the live 4000 ms timeout."))
    }

    @Test func reportSkipsLLMSectionsWhenTheLLMIsOff() {
        let row = EvalRow(id: "x", reference: "好", raw: "好", refined: nil)
        let md = EvalReport.markdown(mixed: [], correct: [row], cleanup: [row], rewrite: [row], llmEnabled: false, header: "h")
        #expect(md.components(separatedBy: "Skipped: LLM not configured.").count == 4)
        #expect(!md.contains("False-correction rate"))
    }
}

@Suite struct SmokeVerdictTests {
    let good = [SmokeVerdict.Clip(id: "m01", cer: 0.15), SmokeVerdict.Clip(id: "m02", cer: 0.2)]

    @Test func healthyRunPasses() {
        #expect(SmokeVerdict.failures(clips: good, errors: []).isEmpty)
    }

    @Test func catchesTheBugsThatShipped() {
        // Silent fallback surfaced as an error per clip.
        #expect(!SmokeVerdict.failures(clips: [], errors: ["m01: modelDownloading"]).isEmpty)
        // Final text truncated to one character.
        let truncated = [SmokeVerdict.Clip(id: "m01", cer: 0.95), SmokeVerdict.Clip(id: "m02", cer: 1.0)]
        #expect(SmokeVerdict.failures(clips: truncated, errors: []).count == 1)
    }
}

@Suite struct SettingsTests {
    func freshDefaults() -> UserDefaults {
        let name = "fnvoice-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsToSimplifiedChineseAndLLMOff() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.language == .simplifiedChinese)
        #expect(s.language.rawValue == "zh-CN")
        #expect(!s.llmEnabled)
    }

    @Test func persistsChoices() {
        let d = freshDefaults()
        AppSettings(defaults: d).language = .japanese
        AppSettings(defaults: d).llmEnabled = true
        #expect(AppSettings(defaults: d).language == .japanese)
        #expect(AppSettings(defaults: d).llmEnabled)
    }

    @Test func unknownStoredLanguageFallsBackToDefault() {
        let d = freshDefaults()
        d.set("xx-XX", forKey: "dictationLanguage")
        #expect(AppSettings(defaults: d).language == .simplifiedChinese)
    }

    @Test func offersTheFiveLanguages() {
        #expect(DictationLanguage.allCases.map(\.rawValue) == ["en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR"])
    }

    @Test func vocabularyParsingAndMerging() {
        let user = Vocabulary.parse("# comment\n\nFnVoice\n  python  \nTauri\n")
        #expect(user == ["FnVoice", "python", "Tauri"])
        let merged = Vocabulary.merged(user: user)
        #expect(merged.prefix(3) == ["FnVoice", "python", "Tauri"])
        #expect(!merged.contains("Python")) // case-insensitive de-dupe keeps the user's spelling
        #expect(merged.count <= 100)
        #expect(Vocabulary.merged(user: [], limit: 5).count == 5)
    }

    @Test func recognitionEngineResolution() {
        #expect(RecognitionEngine.resolve(stored: nil, analyzerAvailable: true) == RecognitionEngine.preferredDefault)
        #expect(RecognitionEngine.resolve(stored: .legacy, analyzerAvailable: true) == .legacy)
        #expect(RecognitionEngine.resolve(stored: .dictationTranscriber, analyzerAvailable: true) == .dictationTranscriber)
        // On macOS 14/15 every SpeechAnalyzer engine falls back to legacy.
        for e in RecognitionEngine.allCases {
            #expect(RecognitionEngine.resolve(stored: e, analyzerAvailable: false) == .legacy)
        }
        #expect(RecognitionEngine.resolve(stored: nil, analyzerAvailable: false) == .legacy)
    }

    @Test func recognitionEnginePersists() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).recognitionEngine == nil)
        AppSettings(defaults: d).recognitionEngine = .dictationTranscriber
        #expect(AppSettings(defaults: d).recognitionEngine == .dictationTranscriber)
        AppSettings(defaults: d).recognitionEngine = nil
        #expect(AppSettings(defaults: d).recognitionEngine == nil)
    }

    @Test func fnUsageHint() {
        #expect(!FnUsageType.needsHint(rawValue: 0))
        #expect(FnUsageType.needsHint(rawValue: 1))
        #expect(FnUsageType.needsHint(rawValue: 2))
        #expect(FnUsageType.needsHint(rawValue: 3))
        #expect(FnUsageType.needsHint(rawValue: nil))
    }
}
