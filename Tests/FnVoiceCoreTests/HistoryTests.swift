import Foundation
import Testing
@testable import FnVoiceCore

@Suite struct DictationHistoryTests {
    func record(raw: String, pasted: String?, final: String?, llm: DictationRecord.LLM = .ok, total: Int? = 400) -> DictationRecord {
        var r = DictationRecord(engine: "speechTranscriber", language: "zh-CN", raw: raw, input: raw, llm: llm)
        r.pasted = pasted
        r.final = final
        r.totalMs = total
        return r
    }

    @Test func roundTripsThroughJSONLAndKeepsChineseReadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.jsonl")
        let a = record(raw: "我在用配森", pasted: "我在用 Python", final: "我在用 Python")
        let b = record(raw: "hello", pasted: nil, final: nil, llm: .skipped)
        try DictationHistory.append(a, to: url)
        try DictationHistory.append(b, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.contains("我在用配森"))
        let parsed = DictationHistory.parse(text + "{truncated\n\n")
        #expect(parsed.count == 2)
        #expect(parsed[0].id == a.id && parsed[0].final == "我在用 Python" && parsed[1].llm == .skipped)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func groupsSwapOutcomesByTargetApp() {
        func at(_ app: String?, replaced: String? = nil, missed: String? = nil) -> DictationRecord {
            var r = record(raw: "a", pasted: "a", final: nil)
            r.app = app
            r.fieldReadable = app != nil
            r.replaced = replaced
            r.replaceError = missed
            return r
        }
        let table = appTable([
            at("com.google.Chrome", missed: "skipped: selection not accepted"),
            at("com.google.Chrome", missed: "skipped: selection not accepted"),
            at("com.google.Chrome", missed: "skipped: text moved"),
            at("com.apple.Notes", replaced: "b"),
            at(nil),
        ])
        #expect(table.contains("| com.google.Chrome | 3 | 3 | 0 | 3 | skipped: selection not accepted (2) |"))
        #expect(table.contains("| com.apple.Notes | 1 | 1 | 1 | 0 | - |"))
        #expect(appTable([at(nil)]).isEmpty)

        var r = at("com.google.Chrome")
        r.fieldReadable = false
        let back = DictationHistory.parse(DictationHistory.encode(r)!)
        #expect(back.first?.app == "com.google.Chrome")
        #expect(back.first?.fieldReadable == false)
    }

    @Test func mapsFallbackReasons() {
        #expect(DictationRecord.status(fallbackReason: nil) == .ok)
        #expect(DictationRecord.status(fallbackReason: "guardrail: too many edits") == .guardrail)
        #expect(DictationRecord.status(fallbackReason: LLMError.timeout.userMessage) == .timeout)
        #expect(DictationRecord.status(fallbackReason: "HTTP 500") == .error)
    }

    @Test func whitespaceOnlyChangesAreNotEdits() {
        #expect(!record(raw: "", pasted: "用 Python 写", final: "用Python写").userEdited)
        #expect(record(raw: "", pasted: "写带码", final: "写代码").userEdited)
        #expect(!record(raw: "", pasted: "写带码", final: nil).userEdited)
    }

    @Test func percentilesUseNearestRank() {
        #expect(LiveEval.percentile([], 0.5) == nil)
        #expect(LiveEval.percentile([300, 100, 200], 0.5) == 200)
        #expect(LiveEval.percentile(Array(1...10), 0.9) == 9)
    }

    @Test func reportScoresAgainstFinalTextAndFindsRegressions() {
        let rows = [
            // Typed right back then, re-run now gets it wrong: a regression.
            LiveEval.Row(record: record(raw: "跑单元测试", pasted: "跑单元测试", final: "跑单元测试"),
                         rerun: "跑单原测试", rerunLLM: .ok, rerunMs: 900),
            // Typed wrong back then, the user fixed it, re-run gets it right: a fix.
            LiveEval.Row(record: record(raw: "用都可能部署", pasted: "用都可能部署", final: "用 Docker 部署", llm: .guardrail),
                         rerun: "用 Docker 部署", rerunLLM: .ok, rerunMs: 1100),
            // Final text never observed: counted in live stats, not scored.
            LiveEval.Row(record: record(raw: "你好", pasted: "你好", final: nil, llm: .timeout, total: 4300),
                         rerun: "你好", rerunLLM: .skipped),
        ]
        let report = LiveEval.markdown(rows: rows, header: "test")
        #expect(report.contains("## Recorded dictations (3)"))
        #expect(report.contains("| guardrail | 1 | 33.3% |"))
        #expect(report.contains("| timeout | 1 | 33.3% |"))
        #expect(report.contains("Accuracy against your final text (2 dictations)"))
        #expect(report.contains("newly gets 1 right and newly gets 1 wrong"))
        #expect(report.contains("### Regressions"))
        #expect(report.contains("跑单原测试"))
        #expect(report.contains("| current refinement (re-run) |"))
    }

    @Test func reportWithoutObservedFinalsStillGivesLiveStats() {
        let rows = [LiveEval.Row(record: record(raw: "a", pasted: "a", final: nil, total: 350))]
        let report = LiveEval.markdown(rows: rows, header: "h")
        #expect(report.contains("| **Fn-up → typed** | 350 ms | 350 ms | 1 |"))
        #expect(report.contains("No dictation has an observed final text yet"))
    }
}
