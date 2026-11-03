import AppKit
import FnVoiceCore

/// `FnVoice --selftest-inject --probe <InjectProbe.app> --out <file> --text <text> [--input-source <id>]`
///
/// Drives the real injection path into InjectProbe and checks three things: the probe received
/// exactly the text, the original multi-type clipboard came back, and the original input source
/// was restored. Prints a JSON line; exit 0 on pass, 1 on fail, 2 when it couldn't run.
@MainActor enum InjectSelfTest {
    static let sentinelType = NSPasteboard.PasteboardType("com.local.fnvoice.sentinel")

    static func run(arguments args: [String]) async -> Int32 {
        guard let probePath = argumentValue("--probe", in: args),
              let outPath = argumentValue("--out", in: args),
              let text = argumentValue("--text", in: args) else {
            print("usage: FnVoice --selftest-inject --probe InjectProbe.app --out file --text TEXT [--input-source ID|cjk]")
            return 2
        }
        guard AXIsProcessTrusted() else {
            print(#"{"result":"skipped","reason":"FnVoice.app lacks Accessibility permission (needed to post Cmd+V)"}"#)
            return 2
        }

        let inputSources = TISInputSources()
        if var wanted = argumentValue("--input-source", in: args) {
            // "cjk" = whichever CJK input method the user has enabled (Pinyin, Shuangpin, Sogou...).
            if wanted == "cjk" {
                guard let cjk = inputSources.available().first(where: { InputSourcePolicy.isCJK($0) && $0.isSelectable }) else {
                    print(#"{"result":"skipped","reason":"no CJK input method enabled"}"#)
                    return 2
                }
                wanted = cjk.id
            }
            guard inputSources.select(id: wanted) else {
                print(#"{"result":"skipped","reason":"input source \#(wanted) not enabled"}"#)
                return 2
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let sourceBefore = inputSources.current()?.id ?? "?"

        // Multi-type clipboard sentinel: a string and a custom binary type.
        let pb = NSPasteboard.general
        let marker = "FNVOICE-SENTINEL-\(UUID().uuidString)"
        let blob = Data((0..<64).map { UInt8($0) })
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(marker, forType: .string)
        item.setData(blob, forType: sentinelType)
        pb.writeObjects([item])

        try? FileManager.default.removeItem(atPath: outPath)
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--out", outPath]
        config.activates = true
        config.createsNewApplicationInstance = true
        let probe: NSRunningApplication
        do {
            probe = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: probePath), configuration: config)
        } catch {
            print(#"{"result":"skipped","reason":"cannot launch probe: \#(error.localizedDescription)"}"#)
            return 2
        }
        defer { probe.terminate() }

        // Wait until the probe has been frontmost continuously for 500 ms; the app that lost focus
        // when the previous probe quit can grab it back in the meantime.
        var stableFor = 0
        for _ in 0..<80 where stableFor < 5 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == probe.processIdentifier {
                stableFor += 1
            } else {
                stableFor = 0
                probe.activate()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let probeFrontmost = stableFor >= 5

        let injector = TextInjector(
            pasteboard: SystemPasteboard(), inputSources: inputSources,
            poster: CGKeystrokePoster(), system: SystemProbe()
        )
        let report: InjectionReport
        do {
            report = try await injector.inject(text, expectedPID: probe.processIdentifier)
        } catch {
            print(#"{"result":"fail","reason":"injection threw \#(error)"}"#)
            return 1
        }
        try? await Task.sleep(for: .milliseconds(500))

        let received = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        let clipboardOK = pb.string(forType: .string) == marker && pb.data(forType: sentinelType) == blob
        let sourceAfter = inputSources.current()?.id ?? "?"
        let pass = received == text && clipboardOK && sourceAfter == sourceBefore

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let result: [String: Any] = [
            "frontmostAtCheck": frontmost,
            "probeWasFrontmost": probeFrontmost,
            "postEventAccess": CGPreflightPostEventAccess(),
            "result": pass ? "pass" : "fail",
            "textMatches": received == text,
            "received": received,
            "clipboardRestored": clipboardOK,
            "inputSourceBefore": sourceBefore,
            "inputSourceAfter": sourceAfter,
            "switchedInputSource": report.switchedInputSource,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return pass ? 0 : 1
    }
}
