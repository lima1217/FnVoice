import Foundation
import Testing
@testable import FnVoiceCore

@MainActor final class Journal {
    var entries: [String] = []
}

@MainActor final class FakePasteboard: PasteboardAccess {
    let journal: Journal
    var changeCount = 0
    var items: [PasteboardItemSnapshot]
    /// Simulates the user copying something while the paste is in flight.
    var bumpOnPaste = false

    init(journal: Journal, items: [PasteboardItemSnapshot]) {
        self.journal = journal
        self.items = items
    }

    func snapshot() -> [PasteboardItemSnapshot] { items }
    func restore(_ items: [PasteboardItemSnapshot]) {
        self.items = items
        changeCount += 1
        journal.entries.append("restoreClipboard")
    }
    func writeTransient(_ text: String) -> Int {
        items = [PasteboardItemSnapshot(entries: [PasteboardEntry(type: "public.utf8-plain-text", data: Data(text.utf8))])]
        changeCount += 1
        journal.entries.append("writeTransient")
        return changeCount
    }
    func writePlain(_ text: String) {
        items = [PasteboardItemSnapshot(entries: [PasteboardEntry(type: "public.utf8-plain-text", data: Data(text.utf8))])]
        changeCount += 1
        journal.entries.append("writePlain")
    }
}

@MainActor final class FakeInputSources: InputSourceControl {
    let journal: Journal
    var currentID: String
    var all: [InputSourceInfo]
    /// IDs whose selection silently doesn't take effect.
    var stuck: Set<String> = []

    init(journal: Journal, current: String, all: [InputSourceInfo]) {
        self.journal = journal
        self.currentID = current
        self.all = all
    }

    func current() -> InputSourceInfo? { all.first { $0.id == currentID } }
    func available() -> [InputSourceInfo] { all }
    func select(id: String) -> Bool {
        journal.entries.append("select:\(id)")
        guard all.contains(where: { $0.id == id }) else { return false }
        if !stuck.contains(id) { currentID = id }
        return true
    }
}

@MainActor final class FakePoster: KeystrokePoster {
    let journal: Journal
    let pasteboard: FakePasteboard
    let inputs: FakeInputSources
    var sourceAtPaste: String?

    init(journal: Journal, pasteboard: FakePasteboard, inputs: FakeInputSources) {
        self.journal = journal
        self.pasteboard = pasteboard
        self.inputs = inputs
    }

    func postPaste() {
        journal.entries.append("paste")
        sourceAtPaste = inputs.currentID
        if pasteboard.bumpOnPaste { pasteboard.changeCount += 1 }
    }
}

@MainActor final class FakeProbe: SystemStateProbe {
    var isSecureInputEnabled = false
    var pid: Int32? = 100
    func frontmostPID() -> Int32? { pid }
}

let abc = InputSourceInfo(id: "com.apple.keylayout.ABC", isKeyboardLayout: true, languages: ["en"], isASCIICapable: true)
let pinyin = InputSourceInfo(id: "com.apple.inputmethod.SCIM.ITABC", isKeyboardLayout: false, languages: ["zh-Hans"], isASCIICapable: true)

@MainActor struct Rig {
    let journal = Journal()
    let pasteboard: FakePasteboard
    let inputs: FakeInputSources
    let poster: FakePoster
    let probe = FakeProbe()
    let injector: TextInjector
    let original = [
        PasteboardItemSnapshot(entries: [
            PasteboardEntry(type: "public.utf8-plain-text", data: Data("original".utf8)),
            PasteboardEntry(type: "public.rtf", data: Data("{\\rtf1 original}".utf8)),
        ]),
        PasteboardItemSnapshot(entries: [PasteboardEntry(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47]))]),
    ]

    init(current: String) {
        pasteboard = FakePasteboard(journal: journal, items: original)
        inputs = FakeInputSources(journal: journal, current: current, all: [abc, pinyin])
        poster = FakePoster(journal: journal, pasteboard: pasteboard, inputs: inputs)
        injector = TextInjector(pasteboard: pasteboard, inputSources: inputs, poster: poster, system: probe, sleep: { _ in })
    }
}

@MainActor @Suite struct TextInjectorTests {
    @Test func asciiSourcePastesWithoutSwitching() async throws {
        let rig = Rig(current: abc.id)
        let report = try await rig.injector.inject("hello", expectedPID: 100)
        #expect(rig.journal.entries == ["writeTransient", "paste", "restoreClipboard"])
        #expect(report == InjectionReport(switchedInputSource: false, inputSourceRestored: true, clipboardRestored: true))
    }

    @Test func cjkSourceSwitchesToABCBeforePasteAndRestoresAfter() async throws {
        let rig = Rig(current: pinyin.id)
        let report = try await rig.injector.inject("你好 Python", expectedPID: 100)
        #expect(rig.journal.entries == ["writeTransient", "select:\(abc.id)", "paste", "select:\(pinyin.id)", "restoreClipboard"])
        #expect(rig.poster.sourceAtPaste == abc.id)
        #expect(rig.inputs.currentID == pinyin.id)
        #expect(report.switchedInputSource && report.inputSourceRestored)
    }

    @Test func clipboardRestoredWithEveryItemAndType() async throws {
        let rig = Rig(current: pinyin.id)
        _ = try await rig.injector.inject("x", expectedPID: nil)
        #expect(rig.pasteboard.items == rig.original)
    }

    @Test func clipboardNotRestoredIfUserCopiedMeanwhile() async throws {
        let rig = Rig(current: abc.id)
        rig.pasteboard.bumpOnPaste = true
        let report = try await rig.injector.inject("x", expectedPID: 100)
        #expect(!report.clipboardRestored)
        #expect(!rig.journal.entries.contains("restoreClipboard"))
    }

    @Test func secureInputRefusesWithoutTouchingAnything() async {
        let rig = Rig(current: abc.id)
        rig.probe.isSecureInputEnabled = true
        await #expect(throws: InjectionError.secureInput) {
            try await rig.injector.inject("secret", expectedPID: 100)
        }
        #expect(rig.journal.entries.isEmpty)
        #expect(rig.pasteboard.items == rig.original)
    }

    @Test func focusChangeLeavesTextOnClipboardAndDoesNotPaste() async {
        let rig = Rig(current: abc.id)
        rig.probe.pid = 200
        await #expect(throws: InjectionError.focusChanged) {
            try await rig.injector.inject("text", expectedPID: 100)
        }
        #expect(rig.journal.entries == ["writePlain"])
        #expect(rig.pasteboard.items.first?.entries.first?.data == Data("text".utf8))
    }

    @Test func switchThatNeverTakesEffectStillPastesAndRestoresAfterTimeout() async throws {
        let rig = Rig(current: pinyin.id)
        rig.inputs.stuck = [abc.id]
        let report = try await rig.injector.inject("x", expectedPID: 100)
        #expect(rig.journal.entries.contains("paste"))
        #expect(report.inputSourceRestored) // never left pinyin, so "restored" holds
    }

    @Test func failedRestoreIsReported() async throws {
        let rig = Rig(current: pinyin.id)
        rig.inputs.stuck = [pinyin.id] // can switch away, can't switch back
        let report = try await rig.injector.inject("x", expectedPID: 100)
        #expect(report.switchedInputSource)
        #expect(!report.inputSourceRestored)
    }

    @Test func emptyOriginalClipboardIsRestoredEmpty() async throws {
        let rig = Rig(current: abc.id)
        rig.pasteboard.items = []
        _ = try await rig.injector.inject("x", expectedPID: 100)
        #expect(rig.pasteboard.items.isEmpty)
    }

    /// The clipboard-restore delay counts from the paste and overlaps the post-paste wait, so a
    /// paste costs max(afterPaste, clipboardRestoreDelay), not their sum.
    @Test func clipboardDelayOverlapsThePostPasteWait() async throws {
        let rig = Rig(current: abc.id)
        var timing = InjectionTiming()
        timing.afterPaste = .milliseconds(200)
        timing.clipboardRestoreDelay = .milliseconds(200)
        let injector = TextInjector(
            pasteboard: rig.pasteboard, inputSources: rig.inputs, poster: rig.poster, system: rig.probe, timing: timing
        )
        let start = ContinuousClock.now
        _ = try await injector.inject("x", expectedPID: 100)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(350), "took \(elapsed); the two waits ran one after the other")
        #expect(rig.journal.entries == ["writeTransient", "paste", "restoreClipboard"])
    }
}

@Suite struct InputSourcePolicyTests {
    func method(_ id: String, _ langs: [String]) -> InputSourceInfo {
        InputSourceInfo(id: id, isKeyboardLayout: false, languages: langs, isASCIICapable: true)
    }

    @Test func recognizesCJKInputMethods() {
        #expect(InputSourcePolicy.isCJK(pinyin))
        #expect(InputSourcePolicy.isCJK(method("com.apple.inputmethod.TCIM.Zhuyin", ["zh-Hant"])))
        #expect(InputSourcePolicy.isCJK(method("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", ["ja"])))
        #expect(InputSourcePolicy.isCJK(method("com.apple.inputmethod.Korean.2SetKorean", ["ko"])))
        // Third-party IMEs that misreport their language.
        #expect(InputSourcePolicy.isCJK(method("com.sogou.inputmethod.sogou.pinyin", ["en"])))
        #expect(InputSourcePolicy.isCJK(method("com.tencent.inputmethod.wetype.pinyin", [])))
        #expect(InputSourcePolicy.isCJK(method("im.rime.inputmethod.Squirrel.Hans", [])))
        // Unknown IME with a CJK language.
        #expect(InputSourcePolicy.isCJK(method("com.example.ime", ["zh-Hans"])))
    }

    @Test func keyboardLayoutsAndOtherMethodsAreNotCJK() {
        #expect(!InputSourcePolicy.isCJK(abc))
        let pinyinLayoutLike = InputSourceInfo(id: "com.apple.keylayout.PinyinKeyboard", isKeyboardLayout: true, languages: ["zh"], isASCIICapable: true)
        #expect(!InputSourcePolicy.isCJK(pinyinLayoutLike))
        #expect(!InputSourcePolicy.isCJK(method("com.apple.inputmethod.Vietnamese", ["vi"])))
    }

    @Test func asciiTargetPrefersABCThenUSThenAnyAsciiLayout() {
        let us = InputSourceInfo(id: "com.apple.keylayout.US", isKeyboardLayout: true, languages: ["en"], isASCIICapable: true)
        let dvorak = InputSourceInfo(id: "com.apple.keylayout.Dvorak", isKeyboardLayout: true, languages: ["en"], isASCIICapable: true)
        let russian = InputSourceInfo(id: "com.apple.keylayout.Russian", isKeyboardLayout: true, languages: ["ru"], isASCIICapable: false)
        #expect(InputSourcePolicy.asciiTarget(from: [pinyin, dvorak, us, abc])?.id == abc.id)
        #expect(InputSourcePolicy.asciiTarget(from: [pinyin, dvorak, us])?.id == us.id)
        #expect(InputSourcePolicy.asciiTarget(from: [russian, dvorak])?.id == dvorak.id)
        #expect(InputSourcePolicy.asciiTarget(from: [pinyin, russian]) == nil)
    }
}
