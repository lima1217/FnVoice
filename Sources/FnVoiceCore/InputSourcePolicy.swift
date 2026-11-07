import Foundation

public struct InputSourceInfo: Equatable, Sendable {
    public var id: String
    /// True for plain keyboard layouts (ABC, US, Dvorak...), false for input methods/modes.
    public var isKeyboardLayout: Bool
    public var languages: [String]
    public var isASCIICapable: Bool
    public var isSelectable: Bool

    public init(id: String, isKeyboardLayout: Bool, languages: [String], isASCIICapable: Bool, isSelectable: Bool = true) {
        self.id = id
        self.isKeyboardLayout = isKeyboardLayout
        self.languages = languages
        self.isASCIICapable = isASCIICapable
        self.isSelectable = isSelectable
    }
}

public enum InputSourcePolicy {
    static let cjkLanguagePrefixes = ["zh", "ja", "ko", "yue"]

    /// Input methods known to compose CJK text. Language metadata alone misses some
    /// third-party IMEs, which register as "en" or with no language at all.
    static let cjkIDPrefixes = [
        "com.apple.inputmethod.SCIM",            // Simplified Chinese (Pinyin, Shuangpin, Wubi)
        "com.apple.inputmethod.TCIM",            // Traditional Chinese (Zhuyin, Cangjie, Pinyin)
        "com.apple.inputmethod.TYIM",            // Cantonese
        "com.apple.inputmethod.ChineseHandwriting",
        "com.apple.inputmethod.Kotoeri",         // Japanese
        "com.apple.inputmethod.Korean",
        "com.sogou.inputmethod",
        "com.tencent.inputmethod",               // WeType / QQ Pinyin
        "com.baidu.inputmethod",
        "com.iflytek.inputmethod",
        "im.rime.inputmethod",                   // Squirrel
        "com.google.inputmethod.Japanese",
        "com.justsystems.inputmethod.atok",
    ]

    public static func isCJK(_ source: InputSourceInfo) -> Bool {
        if source.isKeyboardLayout { return false }
        if cjkIDPrefixes.contains(where: { source.id.hasPrefix($0) }) { return true }
        if let lang = source.languages.first?.lowercased() {
            return cjkLanguagePrefixes.contains { lang == $0 || lang.hasPrefix($0 + "-") || lang.hasPrefix($0 + "_") }
        }
        return false
    }

    /// Apple's Chinese input methods pass ⌘V straight through, so pasting needs no switch (`make e2e`
    /// checks the paste lands under Shuangpin). Switching away and back costs something real: the
    /// method comes back in its English mode, and the user has to press Shift to type Chinese again.
    static let pastesThroughIDPrefixes = [
        "com.apple.inputmethod.SCIM",
        "com.apple.inputmethod.TCIM",
    ]

    /// Whether to switch to an ASCII layout for the paste: CJK methods that might swallow ⌘V.
    public static func needsASCIISwitch(_ source: InputSourceInfo) -> Bool {
        isCJK(source) && !pastesThroughIDPrefixes.contains { source.id.hasPrefix($0) }
    }

    /// The ASCII layout to switch to before pasting: ABC, then US, then any ASCII-capable layout.
    public static func asciiTarget(from candidates: [InputSourceInfo]) -> InputSourceInfo? {
        let usable = candidates.filter { $0.isKeyboardLayout && $0.isASCIICapable && $0.isSelectable }
        for preferred in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            if let hit = usable.first(where: { $0.id == preferred }) { return hit }
        }
        return usable.first
    }
}
