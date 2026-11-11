import Foundation

public enum Levenshtein {
    public static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

public enum ErrorRate {
    /// Characters compared for CER: punctuation and whitespace dropped, Latin lowercased,
    /// so "Python，" vs "python" is not an error.
    public static func normalize(_ s: String) -> [Character] {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }.map { $0 }
    }

    /// Equal up to whitespace, punctuation and case: what CER ignores.
    public static func sameWords(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }

    public static func cer(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference)
        let h = normalize(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(Levenshtein.distance(r, h)) / Double(r.count)
    }
}

public struct EvalCase: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Mixed zh/en dictation: run ASR on audio, then refinement; measure CER.
        case mixed
        /// Already-correct text: feed straight to refinement; any change is a false correction.
        case correct
        /// Spoken-style text (fillers, stutters, self-corrections, missing punctuation): feed `input`
        /// to refinement; it passes when the output matches `reference`, punctuation ignored.
        case cleanup
        /// A dictation to be rewritten by intent (an email, a tidy message). There is no single
        /// right answer: `reference` is one acceptable rewrite, and the output passes when
        /// `FactCheck` finds every fact of `input` kept, none invented, and `keep`/`drop` honoured.
        case rewrite
    }

    public var id: String
    public var kind: Kind
    public var reference: String
    /// Audio path relative to the corpus file. Optional for `correct` cases.
    public var audio: String?
    /// What refinement is given, for `cleanup` and `rewrite` cases.
    public var input: String?
    /// `rewrite` cases: what the case tests (verbose, negation, injection, selfcorrect, numbers).
    public var category: String?
    /// `rewrite` cases: words the output must contain (names the fact check can't see).
    public var keep: [String]?
    /// `rewrite` cases: words the output must not contain (a value taken back, an obeyed injection).
    public var drop: [String]?
    /// `correct` and `cleanup` cases: the target app's name, as live dictation passes it to refinement.
    public var app: String?

    public init(id: String, kind: Kind, reference: String, audio: String? = nil, input: String? = nil) {
        self.id = id
        self.kind = kind
        self.reference = reference
        self.audio = audio
        self.input = input
    }

    public static func loadJSONL(_ text: String) throws -> [EvalCase] {
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            .map { try decoder.decode(EvalCase.self, from: Data($0.utf8)) }
    }
}

public struct EvalRow: Sendable {
    public var id: String
    public var reference: String
    public var raw: String?
    public var refined: String?
    public var note: String?
    /// LLM round trip, when the LLM was called.
    public var llmMs: Int?
    /// `rewrite` cases: what the case tests, and the fact check of the output against the input.
    public var category: String?
    public var facts: FactCheck.Result?

    public init(id: String, reference: String, raw: String?, refined: String?, note: String? = nil) {
        self.id = id
        self.reference = reference
        self.raw = raw
        self.refined = refined
        self.note = note
    }
}

public enum EvalReport {
    public static func markdown(
        mixed: [EvalRow], correct: [EvalRow], cleanup: [EvalRow] = [], rewrite: [EvalRow] = [], llmEnabled: Bool, header: String,
        liveTimeoutMs: Int = 4000
    ) -> String {
        var out = "# FnVoice evaluation\n\n\(header)\n\n"
        out += dictation(mixed, llmEnabled: llmEnabled)
        out += latency((mixed + correct + cleanup).compactMap(\.llmMs), liveTimeoutMs: liveTimeoutMs)
        out += dictationRows(mixed)
        out += section("False corrections on already-correct text", llmEnabled: llmEnabled) { falseCorrections(correct) }
        if !cleanup.isEmpty {
            out += section("Cleanup of spoken text (fillers, self-corrections, punctuation)", llmEnabled: llmEnabled) {
                cleanupResults(cleanup)
            }
        }
        if !rewrite.isEmpty {
            out += section("Rewrite by intent (fact preservation)", llmEnabled: llmEnabled) { rewriteResults(rewrite) }
        }
        return out
    }

    /// A report section whose body needs the LLM's output.
    static func section(_ title: String, llmEnabled: Bool, _ body: () -> String) -> String {
        "\n## \(title)\n\n" + (llmEnabled ? body() : "Skipped: LLM not configured.\n")
    }

    static func dictation(_ mixed: [EvalRow], llmEnabled: Bool) -> String {
        let scored = mixed.filter { $0.raw != nil }
        var out = "## Dictation (\(scored.count)/\(mixed.count) transcribed)\n\n"
        out += "| set | cases | mean CER, raw ASR | mean CER, after refinement |\n|---|---|---|---|\n"
        guard !scored.isEmpty else { return out + "| all | 0 | n/a (nothing transcribed; see notes) | n/a |\n" }
        let hasLatin = { (r: EvalRow) in r.reference.contains { $0.isASCII && $0.isLetter } }
        let sets: [(String, [EvalRow])] = [
            ("all", scored),
            ("zh + English terms", scored.filter(hasLatin)),
            ("Chinese only", scored.filter { !hasLatin($0) }),
        ]
        for (name, rows) in sets where !rows.isEmpty {
            let raw = mean(rows.map { ErrorRate.cer(reference: $0.reference, hypothesis: $0.raw ?? "") })
            let refined = mean(rows.map { ErrorRate.cer(reference: $0.reference, hypothesis: $0.refined ?? $0.raw ?? "") })
            out += "| \(name) | \(rows.count) | \(percent(raw)) | \(llmEnabled ? percent(refined) : "n/a (LLM not configured)") |\n"
        }
        return out
    }

    static func latency(_ ms: [Int], liveTimeoutMs: Int) -> String {
        let ms = ms.sorted()
        guard let max = ms.last else { return "" }
        let slow = ms.filter { $0 > liveTimeoutMs }.count
        return "\nLLM latency over \(ms.count) calls: median \(ms[ms.count / 2]) ms, "
            + "p90 \(ms[min(ms.count - 1, ms.count * 9 / 10)]) ms, max \(max) ms; "
            + "\(slow) over the live \(liveTimeoutMs) ms timeout.\n"
    }

    static func dictationRows(_ mixed: [EvalRow]) -> String {
        var out = "\n| id | reference | raw | refined | CER raw | CER refined | note |\n|---|---|---|---|---|---|---|\n"
        for r in mixed {
            let cr = r.raw.map { percent(ErrorRate.cer(reference: r.reference, hypothesis: $0)) } ?? "-"
            let cf = (r.refined ?? r.raw).map { percent(ErrorRate.cer(reference: r.reference, hypothesis: $0)) } ?? "-"
            out += "| \(r.id) | \(tableCell(r.reference)) | \(tableCell(r.raw)) | \(tableCell(r.refined)) | \(cr) | \(cf) | \(tableCell(r.note)) |\n"
        }
        return out
    }

    static func falseCorrections(_ correct: [EvalRow]) -> String {
        // Punctuation fixes are part of the cleanup, so only a change to the words counts.
        let changed = correct.filter { r in r.refined.map { !ErrorRate.sameWords($0, r.reference) } ?? false }
        let rate = correct.isEmpty ? 0 : Double(changed.count) / Double(correct.count)
        var out = "False-correction rate: **\(percent(rate))** (\(changed.count)/\(correct.count)), target 0%.\n\n"
        guard !changed.isEmpty else { return out }
        out += "| id | input | output |\n|---|---|---|\n"
        for r in changed { out += "| \(r.id) | \(tableCell(r.reference)) | \(tableCell(r.refined)) |\n" }
        return out
    }

    static func cleanupResults(_ cleanup: [EvalRow]) -> String {
        let matched = { (r: EvalRow) in r.refined.map { ErrorRate.sameWords($0, r.reference) } ?? false }
        var out = "Matched: **\(cleanup.filter(matched).count)/\(cleanup.count)** (punctuation ignored), target all.\n\n"
        out += "| id | input | expected | output | note |\n|---|---|---|---|---|\n"
        for r in cleanup {
            let mark = matched(r) ? "ok" : "MISS"
            out += "| \(r.id) | \(tableCell(r.raw)) | \(tableCell(r.reference)) | \(tableCell(r.refined)) | \(mark)\(r.note.map { " · " + $0 } ?? "") |\n"
        }
        return out
    }

    static func rewriteResults(_ rewrite: [EvalRow]) -> String {
        let preserved = { (rs: [EvalRow]) in rs.filter { $0.facts?.passed == true }.count }
        var out = "Facts preserved: **\(preserved(rewrite))/\(rewrite.count)**, target all. "
            + "Each output is checked against its input by `FactCheck`: numbers, date words, English words and "
            + "negations kept, none invented, no value the speaker took back, `keep` present, `drop` absent. "
            + "Whether the text was actually rewritten is not scored.\n\n"
        out += "| category | preserved |\n|---|---|\n"
        for (c, rs) in Dictionary(grouping: rewrite, by: { $0.category ?? "-" }).sorted(by: { $0.key < $1.key }) {
            out += "| \(c) | \(preserved(rs))/\(rs.count) |\n"
        }
        out += "\n| id | category | input | output | facts | note |\n|---|---|---|---|---|---|\n"
        for r in rewrite {
            out += "| \(r.id) | \(r.category ?? "-") | \(tableCell(r.raw)) | \(tableCell(r.refined)) | "
                + "\(r.facts.map { $0.passed ? "ok" : "FAIL · " + $0.summary } ?? "-") | \(r.note ?? "") |\n"
        }
        return out
    }

    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
}

/// A share as the eval reports print it: one decimal and a percent sign.
func percent(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

/// Text made safe for one Markdown table cell; nil shows as "-".
func tableCell(_ s: String?) -> String {
    (s ?? "-").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
}

/// Pass/fail rules for `make smoke`: a few corpus clips streamed through the live recognition path.
/// Each rule targets a bug that shipped once: recognition errors or a silent engine fallback,
/// and a truncated final text (one character).
public enum SmokeVerdict {
    public struct Clip: Sendable {
        public var id: String
        public var cer: Double
        public init(id: String, cer: Double) {
            self.id = id
            self.cer = cer
        }
    }

    public static let maxMeanCER = 0.5

    /// Empty when the run passes; otherwise one line per broken rule.
    public static func failures(clips: [Clip], errors: [String]) -> [String] {
        var out = errors.map { "error: \($0)" }
        if clips.isEmpty { out.append("no clip was transcribed") }
        if !clips.isEmpty {
            let mean = clips.map(\.cer).reduce(0, +) / Double(clips.count)
            if mean > maxMeanCER {
                out.append(String(format: "mean CER %.0f%% > %.0f%% (truncated or garbled final text)", mean * 100, maxMeanCER * 100))
            }
        }
        return out
    }
}
