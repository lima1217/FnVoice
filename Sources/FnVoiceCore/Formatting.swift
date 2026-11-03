import Foundation

/// Deterministic spacing between Chinese/Japanese and English, applied to every injected text:
///
/// - exactly one space on both sides of an English word next to Han or Kana (`用 Python 写`);
/// - no space between Han/Kana and plain numbers (`5分钟`, `下午3点`), matching Chinese convention;
/// - no space between Han/Kana characters or next to full-width punctuation;
/// - whitespace elsewhere (English–English, Korean) is kept, collapsed to one space.
///
/// SpeechTranscriber emits `用 Python写` (space before only); the legacy engine emits `用Python写`.
/// Both end up the same.
public enum TextFormatter {
    enum Segment: Equatable {
        case han(Character)        // Han ideographs and Kana: no inter-word spaces
        case latin(String)         // ASCII word containing at least one letter
        case number(String)        // ASCII digits with . : , separators
        case fullWidthPunct(Character)
        case other(Character)      // ASCII punctuation, Hangul, everything else
    }

    public static func format(_ text: String) -> String {
        let (segments, spaced) = segment(text)
        var out = ""
        for (i, seg) in segments.enumerated() {
            if i > 0 {
                out += separator(segments[i - 1], seg, hadSpace: spaced[i])
            }
            switch seg {
            case .han(let c), .fullWidthPunct(let c), .other(let c): out.append(c)
            case .latin(let s), .number(let s): out += s
            }
        }
        return out
    }

    static func separator(_ a: Segment, _ b: Segment, hadSpace: Bool) -> String {
        switch (a, b) {
        case (.han, .latin), (.latin, .han): return " "
        case (.han, _), (_, .han): return ""
        case (.fullWidthPunct, _), (_, .fullWidthPunct): return ""
        default: return hadSpace ? " " : ""
        }
    }

    /// Splits into segments; `spaced[i]` tells whether whitespace preceded segment i.
    static func segment(_ text: String) -> ([Segment], [Bool]) {
        var segments: [Segment] = []
        var spaced: [Bool] = []
        var pendingSpace = false
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            // Trailing joiners belong to the following punctuation, not the word ("Python." → "Python" + ".").
            var trailing = ""
            while let last = word.last, ".-'".contains(last), word.count > 1 {
                trailing = String(last) + trailing
                word.removeLast()
            }
            segments.append(word.contains(where: \.isLetter) ? .latin(word) : .number(word))
            spaced.append(pendingSpace)
            pendingSpace = false
            word = ""
            for c in trailing {
                segments.append(.other(c))
                spaced.append(false)
            }
        }

        func append(_ s: Segment) {
            segments.append(s)
            spaced.append(pendingSpace)
            pendingSpace = false
        }

        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                word.append(ch)
            } else if !word.isEmpty && ch.isASCII && "._+#-':,".contains(ch) {
                word.append(ch)
            } else if ch.isWhitespace {
                flushWord()
                pendingSpace = !segments.isEmpty
            } else {
                flushWord()
                if isHanOrKana(ch) {
                    append(.han(ch))
                } else if isFullWidthPunct(ch) {
                    append(.fullWidthPunct(ch))
                } else {
                    append(.other(ch))
                }
            }
        }
        flushWord()
        return (segments, spaced)
    }

    static func isHanOrKana(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        switch s.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF: return true // Hiragana, Katakana
        default: return s.properties.isIdeographic
        }
    }

    static func isFullWidthPunct(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        switch s.value {
        case 0x3000...0x303F, 0xFF00...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65: return true
        case 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x2014: return true // ‘ ’ “ ” … —
        default: return false
        }
    }
}
