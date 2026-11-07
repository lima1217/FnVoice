import Foundation

/// One finished dictation, as written to `history.jsonl`: what was heard, what was typed, how long
/// each stage took, and what the user left in the field afterwards. Local only.
///
/// The text fields trace the pipeline: `raw` (recognizer) → `input` (after learned auto-replacements;
/// what refinement sees) → `refined` (accepted LLM output, nil when not sent or rejected) →
/// `pasted` (formatted text actually typed) → `replaced` (what the LLM's answer was swapped in as,
/// when the raw text was typed first) → `final` (that span after the user's edits).
public struct DictationRecord: Codable, Equatable, Sendable {
    public enum LLM: String, Codable, Sendable {
        /// Refinement is off or not configured.
        case off
        /// The scope gate kept this text away from the LLM.
        case skipped
        /// The LLM answered and its output passed the edit guardrail.
        case ok
        /// The edit guardrail rejected the LLM output; the raw text was typed.
        case guardrail
        /// No usable answer within the hard timeout.
        case timeout
        /// HTTP, network or decoding failure.
        case error
        /// The raw text was typed and the next dictation started before the LLM answered.
        case abandoned
    }

    public var id: String
    public var time: Date
    public var engine: String
    public var language: String
    public var raw: String
    public var input: String
    public var llm: LLM
    /// Fallback reason when `llm` is guardrail / timeout / error.
    public var llmReason: String?
    public var model: String?
    public var refined: String?
    /// nil when injection was refused (e.g. Secure Input); see `injectError`.
    public var pasted: String?
    public var injectError: String?
    /// What the LLM wrote when the edit guard rejected it, or put part of it back. Kept so rejected
    /// answers can be read later; `refined` holds only what was accepted.
    public var rejected: String?
    /// Text swapped in for `pasted` once the LLM answered (type-first dictations only).
    public var replaced: String?
    /// Why a changed answer was not swapped in: "skipped: text moved", "skipped: app changed", or an injection error.
    public var replaceError: String?
    /// The pasted span after the user finished editing it. nil when the field couldn't be read
    /// (no Accessibility, password field, text no longer found right after pasting) or watching is off.
    public var final: String?
    public var setupMs: Int?
    public var asrMs: Int?
    public var llmMs: Int?
    public var pasteMs: Int?
    /// Fn-up → text typed: what the user waits for.
    public var totalMs: Int?
    /// LLM answer → swapped in, for type-first dictations.
    public var replaceMs: Int?
    public var partials: Int?
    /// Bundle id of the app that was frontmost at Fn-down (where the text went). Field behaviour
    /// differs by app: Chromium/Electron fields, for one, apply AX selections asynchronously.
    public var app: String?
    /// Whether the focused field was readable at Fn-down, i.e. whether the dictation typed first
    /// and could swap the LLM answer in later.
    public var fieldReadable: Bool?

    public init(
        id: String = UUID().uuidString, time: Date = Date(), engine: String, language: String,
        raw: String, input: String, llm: LLM = .off
    ) {
        self.id = id
        self.time = time
        self.engine = engine
        self.language = language
        self.raw = raw
        self.input = input
        self.llm = llm
    }

    /// Maps a refinement fallback reason (see `Refiner.refine`) onto a status.
    public static func status(fallbackReason: String?) -> LLM {
        guard let reason = fallbackReason else { return .ok }
        if reason.hasPrefix("guardrail") { return .guardrail }
        if reason == LLMError.timeout.userMessage { return .timeout }
        return .error
    }

    /// The text as FnVoice left it in the field: the swapped-in answer, else what was typed.
    public var typed: String? { replaced ?? pasted }

    /// `final`, unless only whitespace is left: chat fields clear to an empty line once the message
    /// is sent, which says nothing about what the user wanted typed.
    public var observedFinal: String? {
        final.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    }

    /// True when the user changed the text FnVoice left (whitespace-only changes don't count).
    public var userEdited: Bool {
        guard let final = observedFinal, let typed else { return false }
        return final.filter { !$0.isWhitespace } != typed.filter { !$0.isWhitespace }
    }
}

/// Per target app: dictations, readable fields, swaps done and missed, and the commonest miss
/// reason. Empty when no record carries an app (history written before the field existed).
func appTable(_ records: [DictationRecord]) -> String {
    let byApp = Dictionary(grouping: records.filter { $0.app != nil }, by: { $0.app! })
    guard !byApp.isEmpty else { return "" }
    var out = "\n| app | dictations | field readable | swapped in | swap missed | top miss reason |\n|---|---|---|---|---|---|\n"
    for (app, rs) in byApp.sorted(by: { $0.value.count > $1.value.count }) {
        let readable = rs.filter { $0.fieldReadable == true }.count
        let swapped = rs.filter { $0.replaced != nil }.count
        let misses = rs.compactMap(\.replaceError)
        let top = Dictionary(grouping: misses, by: { $0 }).max { $0.value.count < $1.value.count }
        out += "| \(app) | \(rs.count) | \(readable) | \(swapped) | \(misses.count) | \(top.map { "\($0.key) (\($0.value.count))" } ?? "-") |\n"
    }
    return out
}

/// Append-only JSONL file of `DictationRecord`s, one object per line.
public enum DictationHistory {
    /// Past this size the file is moved to `history.1.jsonl` (replacing an older one) and restarted.
    /// ~1 KB per dictation, so each file holds roughly 10,000 dictations.
    public static let rotateBytes = 10 * 1024 * 1024

    public static func encode(_ record: DictationRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parses a history file, skipping blank and malformed lines (a crash mid-write leaves at most one).
    public static func parse(_ text: String) -> [DictationRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(DictationRecord.self, from: Data(line.utf8))
        }
    }

    /// Appends one line, creating the directory and file (owner read/write only) if needed.
    public static func append(_ record: DictationRecord, to url: URL) throws {
        guard let line = encode(record) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > rotateBytes {
            let old = url.deletingPathExtension().appendingPathExtension("1.jsonl")
            try? fm.removeItem(at: old)
            try fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// Statistics over recorded dictations and over a re-run of refinement on their real text.
public enum LiveEval {
    public static func percentile(_ xs: [Int], _ p: Double) -> Int? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[i]
    }

    /// One record re-refined with the current prompt, vocabulary and corrections.
    public struct Row: Sendable {
        public var record: DictationRecord
        /// What the current pipeline would type (before formatting), nil if not re-run.
        public var rerun: String?
        public var rerunLLM: DictationRecord.LLM?
        public var rerunReason: String?
        public var rerunMs: Int?

        public init(record: DictationRecord, rerun: String? = nil, rerunLLM: DictationRecord.LLM? = nil,
                    rerunReason: String? = nil, rerunMs: Int? = nil) {
            self.record = record
            self.rerun = rerun
            self.rerunLLM = rerunLLM
            self.rerunReason = rerunReason
            self.rerunMs = rerunMs
        }

        /// What was typed back then, unformatted spacing aside.
        var shipped: String { record.typed ?? record.refined ?? record.input }
    }

    /// Markdown report. Accuracy is scored only against records whose final text was observed; the
    /// user's final text is the reference, so errors they didn't bother to fix count as correct.
    public static func markdown(rows: [Row], header: String) -> String {
        let records = rows.map(\.record)
        var out = "# Live-history eval\n\n\(header)\n\n"

        // Recorded live behaviour.
        out += "## Recorded dictations (\(records.count))\n\n"
        if let first = records.map(\.time).min(), let last = records.map(\.time).max() {
            let f = ISO8601DateFormatter()
            out += "From \(f.string(from: first)) to \(f.string(from: last)).\n\n"
        }
        out += "| stage | p50 | p90 | n |\n|---|---|---|---|\n"
        let stages: [(String, (DictationRecord) -> Int?)] = [
            ("setup (Fn-down → recording)", \.setupMs), ("ASR (Fn-up → text)", \.asrMs),
            ("LLM", \.llmMs), ("paste", \.pasteMs), ("**Fn-up → typed**", \.totalMs),
            ("in-place swap (LLM answer → replaced)", \.replaceMs),
        ]
        for (name, key) in stages {
            let xs = records.compactMap(key)
            out += "| \(name) | \(ms(percentile(xs, 0.5))) | \(ms(percentile(xs, 0.9))) | \(xs.count) |\n"
        }
        let withLLM = records.filter { $0.llm == .ok && $0.llmMs != nil }.compactMap(\.totalMs)
        let withoutLLM = records.filter { $0.llm == .skipped || $0.llm == .off }.compactMap(\.totalMs)
        out += "\nFn-up → typed, p50: \(ms(percentile(withoutLLM, 0.5))) without LLM (n=\(withoutLLM.count)), "
            + "\(ms(percentile(withLLM, 0.5))) with LLM (n=\(withLLM.count)).\n\n"

        out += "| refinement outcome | count | share of sent |\n|---|---|---|\n"
        let sent = records.filter { [.ok, .guardrail, .timeout, .error, .abandoned].contains($0.llm) }.count
        for status in [DictationRecord.LLM.ok, .guardrail, .timeout, .error, .abandoned, .skipped, .off] {
            let n = records.filter { $0.llm == status }.count
            let share = [.skipped, .off].contains(status) || sent == 0 ? "" : pct(Double(n) / Double(sent))
            out += "| \(status.rawValue) | \(n) | \(share) |\n"
        }
        let observed = records.filter { $0.observedFinal != nil }
        let edited = observed.filter(\.userEdited)
        let refused = records.filter { $0.pasted == nil }.count
        out += "\nFinal text observed for \(observed.count) of \(records.count); the user edited \(edited.count) of those. "
            + "Injection refused: \(refused).\n"
        let swapped = records.filter { $0.replaced != nil }.count
        let missed = records.filter { $0.replaceError != nil }.count
        if swapped + missed > 0 {
            out += "LLM answers swapped in after typing: \(swapped); changed answers that could not be swapped in: \(missed).\n"
        }
        out += appTable(records)
        out += "\n"

        // Accuracy against the user's final text.
        let scored = rows.filter { $0.record.observedFinal != nil }
        out += "## Accuracy against your final text (\(scored.count) dictations)\n\n"
        guard !scored.isEmpty else {
            return out + "No dictation has an observed final text yet (needs Accessibility and a readable field).\n"
        }
        func meanCER(_ hyp: (Row) -> String?) -> (Double, Int)? {
            let pairs = scored.compactMap { r in hyp(r).map { (r.record.observedFinal!, $0) } }
            guard !pairs.isEmpty else { return nil }
            let total = pairs.map { ErrorRate.cer(reference: $0.0, hypothesis: $0.1) }.reduce(0, +)
            return (total / Double(pairs.count), pairs.count)
        }
        out += "| text | mean CER vs final | exact match | n |\n|---|---|---|---|\n"
        let variants: [(String, (Row) -> String?)] = [
            ("recognizer (raw)", { $0.record.raw }),
            ("typed back then", { $0.shipped }),
            ("current refinement (re-run)", { $0.rerun }),
        ]
        for (name, hyp) in variants {
            guard let (cer, n) = meanCER(hyp) else {
                out += "| \(name) | - | - | 0 |\n"
                continue
            }
            let exact = scored.filter { r in hyp(r).map { same($0, r.record.observedFinal!) } ?? false }.count
            out += "| \(name) | \(pct(cer)) | \(exact)/\(n) | \(n) |\n"
        }

        let rerun = scored.filter { $0.rerun != nil }
        let regressions = rerun.filter { same($0.shipped, $0.record.observedFinal!) && !same($0.rerun!, $0.record.observedFinal!) }
        let fixes = rerun.filter { !same($0.shipped, $0.record.observedFinal!) && same($0.rerun!, $0.record.observedFinal!) }
        out += "\nAgainst what was typed back then, the current pipeline newly gets \(fixes.count) right "
            + "and newly gets \(regressions.count) wrong.\n"

        let rerunRows = rows.filter { $0.rerunLLM != nil }
        if !rerunRows.isEmpty {
            let sentNow = rerunRows.filter { [.ok, .guardrail, .timeout, .error].contains($0.rerunLLM!) }
            let lat = sentNow.compactMap(\.rerunMs)
            out += "\nRe-run: \(sentNow.count) sent to the LLM, "
                + "guardrail \(sentNow.filter { $0.rerunLLM == .guardrail }.count), "
                + "timeout \(sentNow.filter { $0.rerunLLM == .timeout }.count), "
                + "error \(sentNow.filter { $0.rerunLLM == .error }.count); "
                + "LLM p50 \(ms(percentile(lat, 0.5))), p90 \(ms(percentile(lat, 0.9))).\n"
        }

        func list(_ title: String, _ rs: [Row]) {
            guard !rs.isEmpty else { return }
            out += "\n### \(title)\n\n| time | raw | typed then | re-run | final |\n|---|---|---|---|---|\n"
            let f = ISO8601DateFormatter()
            for r in rs {
                out += "| \(f.string(from: r.record.time)) | \(cell(r.record.raw)) | \(cell(r.shipped)) | "
                    + "\(cell(r.rerun ?? "-"))\(r.rerunReason.map { " (\($0))" } ?? "") | \(cell(r.record.observedFinal!)) |\n"
            }
        }
        list("Regressions (typed right back then, wrong now)", regressions)
        list("Fixes (typed wrong back then, right now)", fixes)
        let regressed = Set(regressions.map(\.record.id))
        list("Still wrong after the re-run", rerun.filter { !same($0.rerun!, $0.record.observedFinal!) && !regressed.contains($0.record.id) })
        return out
    }

    /// Equal up to whitespace, punctuation and case: what CER ignores.
    static func same(_ a: String, _ b: String) -> Bool {
        ErrorRate.normalize(a) == ErrorRate.normalize(b)
    }

    static func ms(_ x: Int?) -> String { x.map { "\($0) ms" } ?? "-" }
    static func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
    static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
