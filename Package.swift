// swift-tools-version:6.0
import PackageDescription

// Any compiler warning (e.g. a Swift 6 Sendable issue) fails the build. App package, never a
// dependency, so unsafeFlags are fine here.
let strict: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "FnVoice",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: state machine, key tracking, waveform math, injection orchestration,
        // LLM client/guardrails, eval metrics. No AppKit, fully unit-testable.
        .target(name: "FnVoiceCore", swiftSettings: strict),
        // The menu-bar app: system adapters (event tap, TIS, NSPasteboard, Speech, Keychain) and UI.
        .executableTarget(name: "FnVoice", dependencies: ["FnVoiceCore"], swiftSettings: strict),
        // Minimal NSTextView app used as an end-to-end injection target.
        .executableTarget(name: "InjectProbe", swiftSettings: strict),
        .testTarget(name: "FnVoiceCoreTests", dependencies: ["FnVoiceCore"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
