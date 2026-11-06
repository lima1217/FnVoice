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
    }

    public var id: String
    public var kind: Kind
    public var reference: String
    /// Audio path relative to the corpus file. Optional for `correct` cases.
    public var audio: String?

    public init(id: String, kind: Kind, reference: String, audio: String? = nil) {
        self.id = id
        self.kind = kind
        self.reference = reference
        self.audio = audio
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
        mixed: [EvalRow], correct: [EvalRow], llmEnabled: Bool, header: String, liveTimeoutMs: Int = 4000
    ) -> String {
        var out = "# FnVoice evaluation\n\n\(header)\n\n"

        let scored = mixed.filter { $0.raw != nil }
        out += "## Dictation (\(scored.count)/\(mixed.count) transcribed)\n\n"
        out += "| set | cases | mean CER, raw ASR | mean CER, after refinement |\n|---|---|---|---|\n"
        if scored.isEmpty {
            out += "| all | 0 | n/a (nothing transcribed; see notes) | n/a |\n"
        } else {
            let sets: [(String, [EvalRow])] = [
                ("all", scored),
                ("zh + English terms", scored.filter { $0.reference.contains { $0.isASCII && $0.isLetter } }),
                ("Chinese only", scored.filter { !$0.reference.contains { $0.isASCII && $0.isLetter } }),
            ]
            for (name, rows) in sets where !rows.isEmpty {
                let raw = mean(rows.map { ErrorRate.cer(reference: $0.reference, hypothesis: $0.raw ?? "") })
                let refined = mean(rows.map { ErrorRate.cer(reference: $0.reference, hypothesis: $0.refined ?? $0.raw ?? "") })
                out += "| \(name) | \(rows.count) | \(pct(raw)) | \(llmEnabled ? pct(refined) : "n/a (LLM not configured)") |\n"
            }
        }
        let latencies = (mixed + correct).compactMap(\.llmMs).sorted()
        if !latencies.isEmpty {
            let slow = latencies.filter { $0 > liveTimeoutMs }.count
            out += "\nLLM latency over \(latencies.count) calls: median \(latencies[latencies.count / 2]) ms, "
                + "p90 \(latencies[min(latencies.count - 1, latencies.count * 9 / 10)]) ms, max \(latencies.last!) ms; "
                + "\(slow) over the live \(liveTimeoutMs) ms timeout.\n"
        }
        out += "\n| id | reference | raw | refined | CER raw | CER refined | note |\n|---|---|---|---|---|---|---|\n"
        for r in mixed {
            let cr = r.raw.map { pct(ErrorRate.cer(reference: r.reference, hypothesis: $0)) } ?? "-"
            let cf = (r.refined ?? r.raw).map { pct(ErrorRate.cer(reference: r.reference, hypothesis: $0)) } ?? "-"
            out += "| \(r.id) | \(cell(r.reference)) | \(cell(r.raw)) | \(cell(r.refined)) | \(cr) | \(cf) | \(cell(r.note)) |\n"
        }

        out += "\n## False corrections on already-correct text\n\n"
        if llmEnabled {
            let changed = correct.filter { $0.refined != nil && $0.refined != $0.reference }
            let rate = correct.isEmpty ? 0 : Double(changed.count) / Double(correct.count)
            out += "False-correction rate: **\(pct(rate))** (\(changed.count)/\(correct.count)), target 0%.\n\n"
            if !changed.isEmpty {
                out += "| id | input | output |\n|---|---|---|\n"
                for r in changed { out += "| \(r.id) | \(cell(r.reference)) | \(cell(r.refined)) |\n" }
            }
        } else {
            out += "Skipped: LLM not configured.\n"
        }
        return out
    }

    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    static func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
    static func cell(_ s: String?) -> String {
        (s ?? "-").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}

/// Pass/fail rules for `make smoke`: a few corpus clips streamed through the live recognition path.
/// Each rule targets a bug that shipped once: recognition errors or a silent engine fallback,
/// an empty capsule while speaking (no partials), and a truncated final text (one character).
public enum SmokeVerdict {
    public struct Clip: Sendable {
        public var id: String
        public var partials: Int
        public var cer: Double
        public init(id: String, partials: Int, cer: Double) {
            self.id = id
            self.partials = partials
            self.cer = cer
        }
    }

    public static let maxMeanCER = 0.5

    /// Empty when the run passes; otherwise one line per broken rule.
    public static func failures(clips: [Clip], errors: [String], expectLiveText: Bool) -> [String] {
        var out = errors.map { "error: \($0)" }
        if clips.isEmpty { out.append("no clip was transcribed") }
        if expectLiveText {
            let silent = clips.filter { $0.partials == 0 }.map(\.id)
            if !silent.isEmpty { out.append("no live text while speaking on \(silent.joined(separator: ", "))") }
        }
        if !clips.isEmpty {
            let mean = clips.map(\.cer).reduce(0, +) / Double(clips.count)
            if mean > maxMeanCER {
                out.append(String(format: "mean CER %.0f%% > %.0f%% (truncated or garbled final text)", mean * 100, maxMeanCER * 100))
            }
        }
        return out
    }
}
