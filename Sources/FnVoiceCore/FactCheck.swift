import Foundation

/// Deterministic fact-preservation check for rewrites: every number, date word, English word and
/// negation the speaker said must survive, nothing of those kinds may be invented, and a value the
/// speaker took back with a correction marker (周三，不对，周四) must not come back.
///
/// It compares fact sets, not wording, so a rewrite may reorder, rephrase and restructure freely:
/// 五万 and 5万 are one value, 三点半 and 3:30 are the same two. It cannot see names or meaning in
/// Chinese words; per-case `keep`/`drop` lists cover those.
public enum FactCheck {
    public enum Kind: String, Sendable, Codable {
        case number, when, latin, negation, term
    }

    public struct Fact: Hashable, Sendable {
        public var kind: Kind
        public var value: String
        public init(_ kind: Kind, _ value: String) {
            self.kind = kind
            self.value = value
        }

        public var display: String {
            if kind == .when, value.count == 2, value.hasPrefix("W"), let d = Int(value.dropFirst()) {
                return "周" + ["一", "二", "三", "四", "五", "六", "日"][d - 1]
            }
            return value
        }
    }

    public struct Result: Equatable, Sendable {
        /// Facts the speaker said (and didn't take back) that the output lost.
        public var missing: [Fact] = []
        /// Facts in the output the speaker never said.
        public var added: [Fact] = []
        /// Values the speaker took back that the output kept anyway.
        public var superseded: [Fact] = []
        public var missingRequired: [String] = []
        public var forbidden: [String] = []

        public var passed: Bool {
            missing.isEmpty && added.isEmpty && superseded.isEmpty && missingRequired.isEmpty && forbidden.isEmpty
        }

        public var summary: String {
            guard !passed else { return "ok" }
            var parts: [String] = []
            func list(_ label: String, _ items: [String]) {
                if !items.isEmpty { parts.append("\(label): \(items.joined(separator: ", "))") }
            }
            list("missing", missing.map(\.display))
            list("added", added.map(\.display))
            list("taken back but kept", superseded.map(\.display))
            list("keep missing", missingRequired)
            list("forbidden", forbidden)
            return parts.joined(separator: "; ")
        }
    }

    public static func check(
        source: String, output: String, vocabulary: [String] = [], keep: [String] = [], drop: [String] = []
    ) -> Result {
        let src = located(source)
        let abandoned = abandonedIndices(src, in: Array(source))
        let active = src.indices.filter { !abandoned.contains($0) }.map { src[$0].fact }
        let all = Set(src.map(\.fact))
        let out = facts(in: output)
        let outSet = Set(out)
        let vocabLatin = Set(vocabulary.flatMap { latinWords(in: $0) })

        var r = Result()
        r.missing = unique(active.filter { $0.kind != .negation && !outSet.contains($0) })
        r.added = unique(out.filter { f in
            f.kind != .negation && !all.contains(f) && !(f.kind == .latin && vocabLatin.contains(f.value))
        })
        let activeSet = Set(active)
        r.superseded = unique(abandoned.sorted().map { src[$0].fact }.filter { !activeSet.contains($0) && outSet.contains($0) })

        let negIn = active.filter { $0.kind == .negation }.count
        let negOut = out.filter { $0.kind == .negation }.count
        if negOut < negIn { r.missing.append(Fact(.negation, "否定 \(negIn)→\(negOut)")) }
        if negOut > negIn { r.added.append(Fact(.negation, "否定 \(negIn)→\(negOut)")) }

        let lowerOutput = output.lowercased()
        r.missing += missingTerms(vocabulary, source: source.lowercased(), output: lowerOutput)
        r.missingRequired = keep.filter { !lowerOutput.contains($0.lowercased()) }
        r.forbidden = drop.filter { lowerOutput.contains($0.lowercased()) }
        return r
    }

    /// First occurrence of each fact, in order.
    static func unique(_ facts: [Fact]) -> [Fact] {
        var seen = Set<Fact>()
        return facts.filter { seen.insert($0).inserted }
    }

    /// Vocabulary terms with no English word in them (飞书) that the source says and the output lost.
    static func missingTerms(_ vocabulary: [String], source: String, output: String) -> [Fact] {
        vocabulary.filter { v in
            latinWords(in: v).isEmpty && source.contains(v.lowercased()) && !output.contains(v.lowercased())
        }.map { Fact(.term, $0) }
    }

    /// Facts in reading order.
    public static func facts(in text: String) -> [Fact] { located(text).map(\.fact) }

    // MARK: - Extraction

    struct Located {
        var fact: Fact
        var range: Range<Int>
    }

    static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    static let bigUnits: [Character: Int] = ["万": 10_000, "亿": 100_000_000]
    /// Numeral runs that are words, not numbers.
    static let numeralWords: Set<String> = ["万一", "一一"]
    /// What a lone 一 must be followed by to count as the number one (一个, 一下 are not facts).
    static let oneUnits: Set<Character> = ["号", "月", "日", "年", "元", "块", "岁"]
    /// A single numeral after one of these is a name (张三, 李四, 王五), not a number.
    static let surnames: Set<Character> = ["张", "李", "王", "赵", "刘", "陈", "杨", "周", "吴", "孙", "钱", "郑"]

    static let whenWords: [(String, String)] = [
        ("下个星期", "下周"), ("上个星期", "上周"), ("这个星期", "本周"), ("下个月", "下月"), ("上个月", "上月"),
        ("这个月", "本月"), ("今天", "今天"), ("明天", "明天"), ("后天", "后天"), ("昨天", "昨天"), ("前天", "前天"),
        ("今晚", "今晚"), ("明晚", "明晚"), ("今早", "今早"), ("明早", "明早"), ("上午", "上午"), ("下午", "下午"),
        ("中午", "中午"), ("晚上", "晚上"), ("早上", "早上"), ("凌晨", "凌晨"), ("傍晚", "傍晚"), ("下周", "下周"),
        ("上周", "上周"), ("本周", "本周"), ("这周", "本周"), ("下月", "下月"), ("本月", "本月"), ("月底", "月底"),
        ("月初", "月初"), ("年底", "年底"), ("周末", "周末"),
    ].sorted { $0.0.count > $1.0.count }
    static let weekdayPrefixes = ["星期", "礼拜", "周"]
    static let weekdayChars: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7]

    static let negations = [
        "千万不要", "千万别", "不要", "不能", "不会", "不用", "不必", "不该", "不想", "不准", "不行", "不是",
        "没有", "无需", "无须", "无法", "禁止", "不", "没", "别", "未", "勿",
    ].sorted { $0.count > $1.count }
    /// Words that contain a negation character but negate nothing.
    static let notNegations = [
        "不错", "不过", "不同", "不少", "不断", "不仅", "不然", "不久", "不管", "不如", "不好意思", "差不多", "不得不",
        "别人", "别的", "特别", "区别", "分别", "级别", "类别", "告别", "别名", "未来",
    ].sorted { $0.count > $1.count }

    static let boundaries: Set<Character> = ["，", "。", ",", "！", "？", "!", "?", "；", ";", "\n", "：", ":"]

    static func latinWords(in s: String) -> [String] {
        located(s).filter { $0.fact.kind == .latin }.map(\.fact.value)
    }

    static func located(_ text: String) -> [Located] {
        var s = Scanner(Array(text))
        // Correction markers and non-negating words first, so their 不/别 aren't read as negations.
        s.scan(EditGuard.correctionMarkers + notNegations) { _ in nil }
        // Weekdays (周三, 下周三, 礼拜五) before plain date words and numbers.
        s.weekdays()
        s.scan(whenWords.map(\.0)) { w in Fact(.when, whenWords.first { $0.0 == w }!.1) }
        s.latinWords()
        // Negations before numbers, so 千万别 isn't read as ten million.
        s.negations()
        s.arabicNumbers()
        s.chineseNumbers()
        return s.found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// One left-to-right pass per fact kind over the same characters; a character taken by an
    /// earlier pass is invisible to later ones.
    struct Scanner {
        let c: [Character]
        var used: [Bool]
        var found: [Located] = []

        init(_ c: [Character]) {
            self.c = c
            used = [Bool](repeating: false, count: c.count)
        }

        func char(_ k: Int) -> Character? { c.indices.contains(k) ? c[k] : nil }

        func matches(_ w: String, at i: Int) -> Bool {
            let w = Array(w)
            guard i >= 0, i + w.count <= c.count else { return false }
            return (0..<w.count).allSatisfy { c[i + $0] == w[$0] && !used[i + $0] }
        }

        mutating func take(_ i: Int, _ n: Int, _ fact: Fact?) {
            for k in i..<(i + n) { used[k] = true }
            if let fact { found.append(Located(fact: fact, range: i..<(i + n))) }
        }

        mutating func scan(_ words: [String], _ fact: (String) -> Fact?) {
            var i = 0
            while i < c.count {
                if let w = words.first(where: { matches($0, at: i) }) {
                    take(i, w.count, fact(w))
                    i += w.count
                } else {
                    i += 1
                }
            }
        }

        // MARK: Weekdays

        static let relativeWeeks: [Character: String] = ["下": "下周", "上": "上周", "这": "本周", "本": "本周"]

        mutating func weekdays() {
            var i = 0
            while i < c.count { i = weekday(at: i) }
        }

        /// Reads 周三 / 下周三 at `i`; returns where to continue.
        mutating func weekday(at i: Int) -> Int {
            var start = i
            if !used[i], let week = Self.relativeWeeks[c[i]],
               weekdayPrefixes.contains(where: { matches($0, at: i + 1) }) {
                take(i, 1, nil)
                found.append(Located(fact: Fact(.when, week), range: i..<(i + 1)))
                start = i + 1
            }
            guard let p = weekdayPrefixes.first(where: { matches($0, at: start) }) else { return i + 1 }
            let d = start + p.count
            if d < c.count, !used[d], let n = weekdayChars[c[d]] {
                take(start, d + 1 - start, Fact(.when, "W\(n)"))
                return d + 1
            }
            return start != i ? d : i + 1
        }

        // MARK: English

        /// English words and identifiers: Python, Next.js, C++, Q3.
        mutating func latinWords() {
            var i = 0
            while i < c.count {
                guard !used[i], c[i].isASCII, c[i].isLetter else { i += 1; continue }
                var j = i
                while j < c.count, !used[j], c[j].isASCII, c[j].isLetter || c[j].isNumber || "._+#-".contains(c[j]) { j += 1 }
                var end = j
                while end > i, ".-_".contains(c[end - 1]) { end -= 1 }
                take(i, end - i, Fact(.latin, String(c[i..<end]).lowercased()))
                i = j
            }
        }

        // MARK: Negations

        /// A-not-A questions (是不是, 有没有) ask rather than negate.
        mutating func negations() {
            for k in c.indices where k > 0 && k + 1 < c.count && !used[k] && (c[k] == "不" || c[k] == "没") && c[k - 1] == c[k + 1] {
                used[k] = true
            }
            scan(FactCheck.negations) { w in Fact(.negation, w) }
        }

        // MARK: Numbers

        func isListMarker(_ start: Int, _ end: Int) -> Bool {
            var k = start - 1
            while k >= 0, c[k] == " " || c[k] == "\t" { k -= 1 }
            guard k < 0 || c[k] == "\n" else { return false }
            return end < c.count && [".", "、", ")", "）"].contains(c[end])
        }

        func afterOrdinal(_ start: Int) -> Bool { char(start - 1) == "第" }

        mutating func number(_ v: Double, _ range: Range<Int>) {
            take(range.lowerBound, range.count, Fact(.number, format(v)))
        }

        func isASCIIDigit(_ k: Int) -> Bool { char(k).map { $0.isASCII && $0.isNumber } ?? false }

        mutating func arabicNumbers() {
            var i = 0
            while i < c.count {
                guard !used[i], isASCIIDigit(i) else { i += 1; continue }
                i = arabicNumber(at: i)
            }
        }

        /// Reads 12, 3.5, 5万, 2千 at `i`; returns where it ends.
        mutating func arabicNumber(at i: Int) -> Int {
            var j = i
            while isASCIIDigit(j) { j += 1 }
            if char(j) == ".", isASCIIDigit(j + 1) {
                j += 1
                while isASCIIDigit(j) { j += 1 }
            }
            var v = Double(String(c[i..<j])) ?? 0
            var end = j
            if let ch = char(j), let u = bigUnits[ch] ?? (ch == "千" ? 1000 : nil) {
                v *= Double(u)
                end = j + 1
            }
            if afterOrdinal(i) || isListMarker(i, j) { take(i, end - i, nil) } else { number(v, i..<end) }
            return end
        }

        func isNumeral(_ k: Int) -> Bool {
            !used[k] && (digits[c[k]] != nil || smallUnits[c[k]] != nil || bigUnits[c[k]] != nil)
        }

        mutating func chineseNumbers() {
            var i = 0
            while i < c.count {
                guard isNumeral(i) else {
                    // 三点半: the 半 is 30 minutes.
                    if !used[i], c[i] == "半", char(i - 1) == "点" { number(30, i..<(i + 1)) }
                    i += 1
                    continue
                }
                var j = i
                while j < c.count, isNumeral(j) { j += 1 }
                chineseRun(i, j)
                i = j
            }
        }

        mutating func chineseRun(_ i: Int, _ j: Int) {
            let run = Array(c[i..<j])
            if !isNumber(run, i, j) { take(i, j - i, nil); return }
            let hasUnit = run.contains { smallUnits[$0] != nil || bigUnits[$0] != nil }
            if !hasUnit && run.count == 2 {
                // 两三天, 七八个: an approximate range, two values.
                number(Double(digits[run[0]]!), i..<(i + 1))
                number(Double(digits[run[1]]!), (i + 1)..<j)
                return
            }
            if let v = chineseValue(run) { number(Double(v), i..<j) } else { take(i, j - i, nil) }
        }

        /// Whether a numeral run reads as a value here, not as part of a word, name or list.
        func isNumber(_ run: [Character], _ i: Int, _ j: Int) -> Bool {
            let next = char(j), prev = char(i - 1)
            guard run.contains(where: { digits[$0] != nil || $0 == "十" }),
                  !numeralWords.contains(String(run)), !afterOrdinal(i),
                  !(run == ["十"] && next == "分" && prev != "点")
            else { return false }
            if run.count == 1 {
                if isListMarker(i, j) || isName(prev: prev, next: next) { return false }
                if run == ["一"] { return isNumberOne(prev: prev, next: next) }
            }
            return true
        }

        /// 张三, 李四: a surname before a single numeral, unless a unit or 点/个 follows.
        func isName(prev: Character?, next: Character?) -> Bool {
            guard let prev, surnames.contains(prev) else { return false }
            guard let next else { return true }
            return !(oneUnits.contains(next) || next == "点" || next == "个")
        }

        /// A lone 一 is the number one before a unit (一号, 一块) or as a time (上午一点), not in 一个, 一下.
        func isNumberOne(prev: Character?, next: Character?) -> Bool {
            guard let next else { return false }
            if oneUnits.contains(next) { return true }
            return next == "点" && prev.map { "午上晚早晨".contains($0) } == true
        }
    }

    static func chineseValue(_ run: [Character]) -> Int? {
        let hasUnit = run.contains { smallUnits[$0] != nil || bigUnits[$0] != nil }
        if !hasUnit {
            // 二零二六, 一九九八: read digit by digit.
            return Int(run.compactMap { digits[$0].map(String.init) }.joined())
        }
        var total = 0, section = 0, n = 0
        for ch in run {
            if let d = digits[ch] {
                n = d
            } else if let u = smallUnits[ch] {
                section += (n == 0 ? 1 : n) * u
                n = 0
            } else if let u = bigUnits[ch] {
                total += (section + n) * u
                section = 0
                n = 0
            }
        }
        return total + section + n
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }

    // MARK: - Self-corrections

    /// Indices of facts the speaker took back: for each run of correction markers, the fact nearest
    /// before it of each kind that is said again right after it (周三，不对，周四 → 周三).
    static func abandonedIndices(_ facts: [Located], in c: [Character]) -> Set<Int> {
        let markers = markerRuns(in: c)
        var abandoned = Set<Int>()
        for n in markers.indices {
            let floor = n > 0 ? markers[n - 1].upperBound : 0
            let ceiling = n + 1 < markers.count ? markers[n + 1].lowerBound : c.count
            let (before, after) = clauses(around: markers[n], floor: floor, ceiling: ceiling, in: c)
            let saidAgain = Set(facts.filter { within($0.range, after) && $0.fact.kind != .negation }.map(\.fact.kind))
            for kind in saidAgain {
                if let k = facts.indices.last(where: { facts[$0].fact.kind == kind && within(facts[$0].range, before) }) {
                    abandoned.insert(k)
                }
            }
        }
        return abandoned
    }

    static func within(_ r: Range<Int>, _ bounds: ClosedRange<Int>) -> Bool {
        r.lowerBound >= bounds.lowerBound && r.upperBound <= bounds.upperBound
    }

    /// Correction markers in `c`, with markers separated only by punctuation or fillers
    /// (不对，不对，嗯，是) merged into one run.
    static func markerRuns(in c: [Character]) -> [Range<Int>] {
        var markers: [Range<Int>] = []
        var i = 0
        while i < c.count {
            guard let m = EditGuard.correctionMarkers.first(where: { w in
                let w = Array(w)
                return i + w.count <= c.count && Array(c[i..<(i + w.count)]) == w
            }) else { i += 1; continue }
            let end = i + m.count
            if let last = markers.last,
               c[last.upperBound..<i].allSatisfy({ boundaries.contains($0) || $0.isWhitespace || EditGuard.fillers.contains(String($0)) }) {
                markers[markers.count - 1] = last.lowerBound..<end
            } else {
                markers.append(i..<end)
            }
            i = end
        }
        return markers
    }

    /// The clause right before a marker run and the one right after it, each stopping at a sentence
    /// boundary or at the neighbouring marker run.
    static func clauses(
        around m: Range<Int>, floor: Int, ceiling: Int, in c: [Character]
    ) -> (before: ClosedRange<Int>, after: ClosedRange<Int>) {
        func isGap(_ ch: Character) -> Bool { boundaries.contains(ch) || ch.isWhitespace }
        var s = m.lowerBound
        while s > 0, isGap(c[s - 1]) { s -= 1 }
        var from = s
        while from > floor, !boundaries.contains(c[from - 1]) { from -= 1 }
        var e = m.upperBound
        while e < c.count, isGap(c[e]) { e += 1 }
        var to = e
        while to < ceiling, !boundaries.contains(c[to]) { to += 1 }
        return (from...s, e...to)
    }
}
