// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FnVoice",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: state machine, key tracking, waveform math, injection orchestration,
        // LLM client/guardrails, eval metrics. No AppKit, fully unit-testable.
        .target(name: "FnVoiceCore"),
        // The menu-bar app: system adapters (event tap, TIS, NSPasteboard, Speech, Keychain) and UI.
        .executableTarget(name: "FnVoice", dependencies: ["FnVoiceCore"]),
        // Minimal NSTextView app used as an end-to-end injection target.
        .executableTarget(name: "InjectProbe"),
        .testTarget(name: "FnVoiceCoreTests", dependencies: ["FnVoiceCore"]),
    ],
    swiftLanguageModes: [.v6]
)
