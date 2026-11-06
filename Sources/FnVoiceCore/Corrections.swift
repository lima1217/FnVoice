import Foundation

/// One learned fix: the recognizer wrote `wrong`, the user changed it to `right`.
public struct Correction: Equatable, Hashable, Sendable {
    public var wrong: String
    public var right: String
    public init(wrong: String, right: String) {
        self.wrong = wrong
        self.right = right
    }
}

/// Finds what the user did to text FnVoice pasted, given snapshots of the field's whole value.
public enum EditRegion {
    /// The pasted span as it reads in `after`, or nil when it can't be told apart from other edits
    /// (the field was cleared, or the user also changed text outside the pasted span).
    /// `range` is the pasted span in `before`, in Characters.
    public static func edited(before: String, after: String, range: Range<Int>) -> String? {
        let a = Array(before), b = Array(after)
        guard range.lowerBound >= 0, range.upperBound <= a.count else { return nil }
        if a == b { return String(a[range]) }
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let changedEnd = a.count - s
        // Text typed or deleted entirely outside the pasted span leaves it as pasted.
        if p >= range.upperBound || changedEnd <= range.lowerBound {
            return String(a[range])
        }
        guard p >= range.lowerBound, changedEnd <= range.upperBound else { return nil }
        let tail = a.count - range.upperBound
        let end = b.count - tail
        guard end >= range.lowerBound else { return nil }
        return String(b[range.lowerBound..<end])
    }
}

/// Turns "what was pasted" vs "what the user left there" into word-level corrections.
public enum CorrectionExtractor {
    /// Max tokens on either side of one correction; longer changes are rewrites, not typo fixes.
    static let maxSpan = 6
    /// Above this share of changed tokens the user rewrote the sentence: learn nothing from it.
    static let maxChangedShare = 0.5

    public static func extract(pasted: String, edited: String) -> [Correction] {
        let a = EditGuard.tokens(pasted), b = EditGuard.tokens(edited)
        guard !a.isEmpty, a != b else { return [] }
        let hunks = EditGuard.alignedHunks(a, b)
        let changed = hunks.reduce(0) { $0 + max($1.a.count, $1.b.count) }
        if Double(changed) / Double(a.count) > maxChangedShare { return [] }

        var out: [Correction] = []
        for h in hunks {
            guard !h.a.isEmpty, !h.b.isEmpty, h.a.count <= maxSpan, h.b.count <= maxSpan else { continue }
            let removed = Array(a[h.a]), added = Array(b[h.b])
            // Punctuation-only edits are style, not recognition errors.
            guard removed.contains(where: isWordToken) || added.contains(where: isWordToken) else { continue }
            guard let (ra, rb) = widened(h, a, b) else { continue }
            let c = Correction(wrong: join(Array(a[ra])), right: join(Array(b[rb])))
            if c.wrong != c.right && !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// A one-character CJK fix (带→代) would rewrite that character everywhere. Pull in unchanged
    /// neighbours, right first, until the wrong side is specific enough (带码→代码).
    static func widened(_ h: EditGuard.AlignedHunk, _ a: [String], _ b: [String]) -> (Range<Int>, Range<Int>)? {
        var ra = h.a, rb = h.b
        var preferRight = true
        while weight(a[ra]) < 2 {
            let canRight = ra.upperBound < a.count && rb.upperBound < b.count && isWordToken(a[ra.upperBound])
            let canLeft = ra.lowerBound > 0 && rb.lowerBound > 0 && isWordToken(a[ra.lowerBound - 1])
            if canRight && (preferRight || !canLeft) {
                ra = ra.lowerBound..<(ra.upperBound + 1); rb = rb.lowerBound..<(rb.upperBound + 1)
            } else if canLeft {
                ra = (ra.lowerBound - 1)..<ra.upperBound; rb = (rb.lowerBound - 1)..<rb.upperBound
            } else {
                return nil
            }
            preferRight.toggle()
        }
        return (ra, rb)
    }

    /// A Latin word is distinctive on its own; a CJK character needs a neighbour.
    static func weight(_ tokens: ArraySlice<String>) -> Int {
        tokens.reduce(0) { $0 + (EditGuard.isLatinWord($1) ? 2 : (isWordToken($1) ? 1 : 0)) }
    }

    static func isWordToken(_ t: String) -> Bool {
        t.contains { $0.isLetter || $0.isNumber }
    }

    /// Rebuilds text from tokens the way `TextFormatter` writes it, so learned pairs match formatted text.
    static func join(_ tokens: [String]) -> String {
        var s = ""
        for (i, t) in tokens.enumerated() {
            if i > 0 && EditGuard.isLatinWord(tokens[i - 1]) && EditGuard.isLatinWord(t) { s += " " }
            s += t
        }
        return TextFormatter.format(s)
    }
}

/// Corrections learned from the user's edits, persisted as an editable text file.
///
/// Seen once, a pair only informs: its right side joins the vocabulary and the pair is shown to the
/// LLM. Seen `autoApplyCount` times, it is replaced in every transcript without the LLM. Changing
/// an auto-replaced word back counts against the rule, so a wrong rule unlearns itself.
public struct CorrectionStore: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var correction: Correction
        public var count: Int
    }

    public static let autoApplyCount = 2
    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    // MARK: Learning

    /// Returns the corrections that just reached the auto-apply threshold.
    @discardableResult
    public mutating func record(_ corrections: [Correction]) -> [Correction] {
        var promoted: [Correction] = []
        for c in corrections {
            let reverse = Correction(wrong: c.right, right: c.wrong)
            if let i = entries.firstIndex(where: { $0.correction == reverse }) {
                entries[i].count -= 1
                if entries[i].count <= 0 { entries.remove(at: i) }
                continue
            }
            if let i = entries.firstIndex(where: { $0.correction == c }) {
                entries[i].count += 1
                if entries[i].count == Self.autoApplyCount { promoted.append(c) }
            } else {
                entries.append(Entry(correction: c, count: 1))
                if Self.autoApplyCount <= 1 { promoted.append(c) }
            }
        }
        entries.sort { $0.count > $1.count }
        return promoted
    }

    // MARK: Using

    /// Rules applied without the LLM: the most-confirmed `right` per `wrong`, longest `wrong` first.
    var activeRules: [Correction] {
        var best: [String: Entry] = [:]
        for e in entries where e.count >= Self.autoApplyCount {
            if let cur = best[e.correction.wrong], cur.count >= e.count { continue }
            best[e.correction.wrong] = e
        }
        return best.values.map(\.correction).sorted { $0.wrong.count > $1.wrong.count }
    }

    /// Replaces confirmed misrecognitions. Latin words match whole words only, and text that already
    /// reads as the right form (不明白 when the rule is 明白→不明白) is left alone.
    public func apply(_ text: String) -> String {
        let rules = activeRules
        guard !rules.isEmpty else { return text }
        var s = TextFormatter.format(text)
        for rule in rules { s = Self.replace(rule, in: s) }
        return s
    }

    static func replace(_ rule: Correction, in text: String) -> String {
        let ns = text as NSString
        var protected: [NSRange] = []
        var r = NSRange(location: 0, length: ns.length)
        while true {
            let f = ns.range(of: rule.right, options: [], range: r)
            if f.location == NSNotFound { break }
            protected.append(f)
            r = NSRange(location: f.upperBound, length: ns.length - f.upperBound)
        }
        var out = ""
        var cursor = 0
        r = NSRange(location: 0, length: ns.length)
        while true {
            let f = ns.range(of: rule.wrong, options: [], range: r)
            if f.location == NSNotFound { break }
            let ok = !protected.contains { NSIntersectionRange($0, f).length > 0 } && isWordBounded(f, in: ns)
            if ok {
                out += ns.substring(with: NSRange(location: cursor, length: f.location - cursor)) + rule.right
                cursor = f.upperBound
            }
            r = NSRange(location: f.upperBound, length: ns.length - f.upperBound)
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func isWordBounded(_ r: NSRange, in s: NSString) -> Bool {
        func isASCIIWordChar(_ u: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(u), scalar.isASCII else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        if isASCIIWordChar(s.character(at: r.location)), r.location > 0, isASCIIWordChar(s.character(at: r.location - 1)) {
            return false
        }
        let last = r.upperBound - 1
        if isASCIIWordChar(s.character(at: last)), r.upperBound < s.length, isASCIIWordChar(s.character(at: r.upperBound)) {
            return false
        }
        return true
    }

    /// True when the text contains something the user corrected before: worth an LLM look.
    public func mentionsKnownMistake(_ text: String) -> Bool {
        let s = TextFormatter.format(text)
        return entries.contains { s.contains($0.correction.wrong) }
    }

    /// Corrected terms, for recognition biasing and the LLM vocabulary.
    public func vocabularyTerms(limit: Int = 30) -> [String] {
        var seen = Set<String>()
        return entries.map(\.correction.right)
            .filter { $0.count >= 2 && seen.insert($0).inserted }
            .prefix(limit).map { $0 }
    }

    /// Pairs shown to the LLM, most-confirmed first.
    public func hints(limit: Int = 30) -> [Correction] {
        Array(entries.prefix(limit).map(\.correction))
    }

    // MARK: File format

    public static let fileHeader = """
    # FnVoice learned corrections, from edits you made to dictated text.
    # Format: wrong → right <tab> times seen. Seen \(autoApplyCount)+ times = replaced automatically.
    # Delete a line to forget it. Changes apply to the next dictation.

    """

    public static func parse(_ contents: String) -> CorrectionStore {
        var entries: [Entry] = []
        for raw in contents.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var pair = line, count = 1
            if let tab = line.lastIndex(of: "\t"), let n = Int(line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)) {
                pair = String(line[..<tab]); count = n
            }
            let parts = pair.components(separatedBy: "→")
            guard parts.count == 2 else { continue }
            let wrong = parts[0].trimmingCharacters(in: .whitespaces), right = parts[1].trimmingCharacters(in: .whitespaces)
            guard !wrong.isEmpty, !right.isEmpty, wrong != right, count > 0 else { continue }
            entries.append(Entry(correction: Correction(wrong: wrong, right: right), count: count))
        }
        return CorrectionStore(entries: entries.sorted { $0.count > $1.count })
    }

    public func serialized() -> String {
        Self.fileHeader + entries.map { "\($0.correction.wrong) → \($0.correction.right)\t\($0.count)\n" }.joined()
    }
}
