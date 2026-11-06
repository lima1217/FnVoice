import Foundation

public struct PasteboardEntry: Equatable, Sendable {
    public var type: String
    public var data: Data
    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// One pasteboard item with every representation it had (plain text, RTF, file URL, image...).
public struct PasteboardItemSnapshot: Equatable, Sendable {
    public var entries: [PasteboardEntry]
    public init(entries: [PasteboardEntry]) { self.entries = entries }
}

@MainActor public protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> [PasteboardItemSnapshot]
    func restore(_ items: [PasteboardItemSnapshot])
    /// Writes text marked transient/concealed so clipboard managers skip it. Returns the new changeCount.
    func writeTransient(_ text: String) -> Int
    /// Writes ordinary text the user is expected to paste themselves.
    func writePlain(_ text: String)
}

@MainActor public protocol InputSourceControl: AnyObject {
    func current() -> InputSourceInfo?
    func available() -> [InputSourceInfo]
    func select(id: String) -> Bool
}

@MainActor public protocol KeystrokePoster: AnyObject {
    func postPaste()
}

@MainActor public protocol SystemStateProbe: AnyObject {
    /// True while a password field (or anything calling EnableSecureEventInput) has focus.
    var isSecureInputEnabled: Bool { get }
    func frontmostPID() -> Int32?
}

public enum InjectionError: Error, Equatable, Sendable {
    case secureInput
    case focusChanged

    public var userMessage: String {
        switch self {
        case .secureInput: "Secure input is on (password field?) — not typed"
        case .focusChanged: "App changed — text copied to clipboard"
        }
    }
}

public struct InjectionReport: Equatable, Sendable {
    public var switchedInputSource: Bool
    public var inputSourceRestored: Bool
    public var clipboardRestored: Bool
}

public struct InjectionTiming: Sendable {
    /// Max time to wait for an input-source switch to take effect.
    public var switchTimeout: Duration = .milliseconds(200)
    public var pollInterval: Duration = .milliseconds(10)
    /// Let the target process the Cmd+V before switching the input source back.
    public var afterPaste: Duration = .milliseconds(80)
    /// The target reads the pasteboard asynchronously; restoring too early pastes the old content.
    public var clipboardRestoreDelay: Duration = .milliseconds(300)

    public init() {}
}

public typealias Sleeper = @Sendable (Duration) async -> Void

/// Clipboard + Cmd+V injection with CJK input-source switching and guarded clipboard restore.
@MainActor public final class TextInjector {
    private let pasteboard: PasteboardAccess
    private let inputSources: InputSourceControl
    private let poster: KeystrokePoster
    private let system: SystemStateProbe
    private let timing: InjectionTiming
    private let sleep: Sleeper

    public init(
        pasteboard: PasteboardAccess,
        inputSources: InputSourceControl,
        poster: KeystrokePoster,
        system: SystemStateProbe,
        timing: InjectionTiming = InjectionTiming(),
        sleep: @escaping Sleeper = { try? await Task.sleep(for: $0) }
    ) {
        self.pasteboard = pasteboard
        self.inputSources = inputSources
        self.poster = poster
        self.system = system
        self.timing = timing
        self.sleep = sleep
    }

    /// - Parameter expectedPID: the app that was frontmost when Fn went down. If the user has
    ///   switched apps since (LLM refinement can take seconds), we don't paste into the wrong place.
    /// - Parameter onPasted: called right after ⌘V is posted (the moment text appears), for latency logging.
    public func inject(_ text: String, expectedPID: Int32?, onPasted: () -> Void = {}) async throws -> InjectionReport {
        if system.isSecureInputEnabled { throw InjectionError.secureInput }
        if let expectedPID, let now = system.frontmostPID(), now != expectedPID {
            pasteboard.writePlain(text)
            throw InjectionError.focusChanged
        }

        let saved = pasteboard.snapshot()
        let ourChangeCount = pasteboard.writeTransient(text)

        let original = inputSources.current()
        var switched = false
        if let original, InputSourcePolicy.isCJK(original),
           let target = InputSourcePolicy.asciiTarget(from: inputSources.available()),
           inputSources.select(id: target.id) {
            switched = true
            _ = await waitUntil { self.inputSources.current()?.id == target.id }
        }

        poster.postPaste()
        onPasted()
        // The clipboard delay counts from the paste, so it runs alongside the input-source
        // restore instead of after it; the caller gets its report that much sooner.
        async let clipboardSettled: Void = sleep(timing.clipboardRestoreDelay)
        await sleep(timing.afterPaste)

        var restoredSource = true
        if switched, let original {
            _ = inputSources.select(id: original.id)
            restoredSource = await waitUntil { self.inputSources.current()?.id == original.id }
        }

        await clipboardSettled
        // If the changeCount moved, the user (or another app) copied something new meanwhile: keep it.
        var restoredClipboard = false
        if pasteboard.changeCount == ourChangeCount {
            pasteboard.restore(saved)
            restoredClipboard = true
        }

        return InjectionReport(
            switchedInputSource: switched,
            inputSourceRestored: restoredSource,
            clipboardRestored: restoredClipboard
        )
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        var waited: Duration = .zero
        while !condition() {
            if waited >= timing.switchTimeout { return false }
            await sleep(timing.pollInterval)
            waited += timing.pollInterval
        }
        return true
    }
}
