import Foundation

public enum DictationLanguage: String, CaseIterable, Sendable {
    case english = "en-US"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    public static let defaultLanguage: DictationLanguage = .simplifiedChinese

    public var displayName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }
}

/// Non-secret preferences. The API key lives in the Keychain, never here.
public final class AppSettings: @unchecked Sendable {
    enum Key {
        static let language = "dictationLanguage"
        static let llmEnabled = "llmRefinementEnabled"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
        static let fnHintShown = "fnUsageHintShown"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var language: DictationLanguage {
        get { defaults.string(forKey: Key.language).flatMap(DictationLanguage.init(rawValue:)) ?? .defaultLanguage }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }

    public var llmEnabled: Bool {
        get { defaults.bool(forKey: Key.llmEnabled) }
        set { defaults.set(newValue, forKey: Key.llmEnabled) }
    }

    public var llmBaseURL: String {
        get { defaults.string(forKey: Key.llmBaseURL) ?? "https://api.deepseek.com/v1" }
        set { defaults.set(newValue, forKey: Key.llmBaseURL) }
    }

    public var llmModel: String {
        get { defaults.string(forKey: Key.llmModel) ?? "" }
        set { defaults.set(newValue, forKey: Key.llmModel) }
    }

    public var fnHintShown: Bool {
        get { defaults.bool(forKey: Key.fnHintShown) }
        set { defaults.set(newValue, forKey: Key.fnHintShown) }
    }
}

/// What the system does when the Fn/Globe key is pressed (com.apple.HIToolbox AppleFnUsageType).
public enum FnUsageType: Int, Sendable {
    case doNothing = 0
    case changeInputSource = 1
    case showEmoji = 2
    case startDictation = 3

    /// Anything but "Do Nothing" can fire alongside our dictation if suppression doesn't hold.
    public static func needsHint(rawValue: Int?) -> Bool {
        guard let rawValue, let t = FnUsageType(rawValue: rawValue) else { return true }
        return t != .doNothing
    }
}

public enum Vocabulary {
    /// Terms the recognizer tends to render as Chinese sound-alikes. Passed as contextualStrings,
    /// which biases recognition at the source, before the LLM ever sees the text.
    public static let builtIn = [
        "Python", "JSON", "Java", "JavaScript", "TypeScript", "Swift", "SwiftUI", "Kotlin", "Rust", "Go",
        "React", "Vue", "Node.js", "npm", "API", "SDK", "HTTP", "HTTPS", "URL", "SQL", "MySQL", "PostgreSQL",
        "Redis", "Docker", "Kubernetes", "Git", "GitHub", "GitLab", "Xcode", "macOS", "iOS", "iPhone", "iPad",
        "Linux", "Ubuntu", "AWS", "Azure", "LLM", "GPT", "ChatGPT", "Claude", "OpenAI", "Anthropic", "prompt",
        "token", "debug", "bug", "commit", "merge", "pull request", "PR", "deploy", "frontend", "backend",
        "CSS", "HTML", "YAML", "Markdown", "CLI", "UI", "UX", "VS Code", "Cursor", "Slack", "Figma", "Notion",
    ]

    /// One term per line; blank lines and `#` comments ignored.
    public static func parse(_ contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// User terms first (they matter most), de-duplicated case-insensitively, capped at Apple's
    /// recommended ~100 contextual strings.
    public static func merged(user: [String], limit: Int = 100) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in user + builtIn where seen.insert(term.lowercased()).inserted {
            out.append(term)
            if out.count == limit { break }
        }
        return out
    }

    public static let fileTemplate = """
    # FnVoice custom vocabulary: one term per line.
    # These bias speech recognition toward the exact spelling (e.g. product names, jargon).
    # Lines starting with # are ignored. Changes apply to the next dictation.

    """
}
