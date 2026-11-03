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
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(cases.filter { $0.kind == .mixed }.allSatisfy { $0.audio != nil })
    }

    @Test func reportComputesFalseCorrectionRate() {
        let mixed = [EvalRow(id: "m1", reference: "我用Python", raw: "我用配森", refined: "我用Python")]
        let correct = [
            EvalRow(id: "c1", reference: "好的", raw: "好的", refined: "好的"),
            EvalRow(id: "c2", reference: "没问题", raw: "没问题", refined: "没问题。"),
        ]
        let md = EvalReport.markdown(mixed: mixed, correct: correct, llmEnabled: true, header: "h")
        #expect(md.contains("False-correction rate: **50.0%** (1/2)"))
        #expect(md.contains("| mean CER, after refinement | 0.0% |"))
    }
}

extension MetricsTests {
    @Test func reportDoesNotClaimZeroCERWhenNothingWasTranscribed() {
        let mixed = [EvalRow(id: "m1", reference: "x", raw: nil, refined: nil, note: "ASR error")]
        let md = EvalReport.markdown(mixed: mixed, correct: [], llmEnabled: false, header: "h")
        #expect(md.contains("n/a (nothing transcribed"))
        #expect(!md.contains("| mean CER, raw ASR | 0.0% |"))
    }
}

@Suite struct SmokeVerdictTests {
    let good = [SmokeVerdict.Clip(id: "m01", partials: 12, cer: 0.15), SmokeVerdict.Clip(id: "m02", partials: 9, cer: 0.2)]

    @Test func healthyRunPasses() {
        #expect(SmokeVerdict.failures(clips: good, errors: [], expectLiveText: true).isEmpty)
    }

    @Test func catchesTheBugsThatShipped() {
        // Silent fallback surfaced as an error per clip.
        #expect(!SmokeVerdict.failures(clips: [], errors: ["m01: modelDownloading"], expectLiveText: true).isEmpty)
        // Empty capsule while speaking.
        let silent = [SmokeVerdict.Clip(id: "m01", partials: 0, cer: 0.1)]
        #expect(SmokeVerdict.failures(clips: silent, errors: [], expectLiveText: true) == ["no live text while speaking on m01"])
        #expect(SmokeVerdict.failures(clips: silent, errors: [], expectLiveText: false).isEmpty)
        // Final text truncated to one character.
        let truncated = [SmokeVerdict.Clip(id: "m01", partials: 5, cer: 0.95), SmokeVerdict.Clip(id: "m02", partials: 5, cer: 1.0)]
        #expect(SmokeVerdict.failures(clips: truncated, errors: [], expectLiveText: true).count == 1)
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

    @Test func liveTextDefaultsOnAndPersists() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).showLiveText)
        AppSettings(defaults: d).showLiveText = false
        #expect(!AppSettings(defaults: d).showLiveText)
    }

    @Test func fnUsageHint() {
        #expect(!FnUsageType.needsHint(rawValue: 0))
        #expect(FnUsageType.needsHint(rawValue: 1))
        #expect(FnUsageType.needsHint(rawValue: 2))
        #expect(FnUsageType.needsHint(rawValue: 3))
        #expect(FnUsageType.needsHint(rawValue: nil))
    }
}
