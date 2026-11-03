import os

/// Transcript text and API keys are never logged at default level; transcripts only appear at
/// debug level with private redaction.
enum Log {
    static let subsystem = "com.local.fnvoice"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let asr = Logger(subsystem: subsystem, category: "asr")
    static let inject = Logger(subsystem: subsystem, category: "inject")
    static let llm = Logger(subsystem: subsystem, category: "llm")
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
