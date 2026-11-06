import AVFoundation
import FnVoiceCore
import Speech

/// `FnVoice --latency-bench <corpus.jsonl> [--engine speechTranscriber] [--clips 10]
///          [--retention whileInUse|lingering|processLifetime] [--prewarm] [--out file.md]`
///
/// Streams corpus audio through `AnalyzerSession` at real-time pace (100 ms chunks, like the mic),
/// and measures what the user waits for. Setup is the time from Fn-down until the analyzer accepts
/// audio. Finalize is end of audio → final text. LLM is the refinement call, only for text the gate sends.
@available(macOS 26.0, *)
@MainActor enum LatencyBench {
    struct Row {
        var id: String
        var setup: Double
        var finalize: Double
        var llm: Double?
        var cer: Double = 0
        var partials = 0
    }

    static func run(arguments args: [String]) async -> Int32 {
        guard let corpusPath = argumentValue("--latency-bench", in: args) else { return 64 }
        let corpusURL = URL(fileURLWithPath: corpusPath)
        let engine = argumentValue("--engine", in: args).flatMap(RecognitionEngine.init(rawValue:)) ?? .speechTranscriber
        guard engine != .legacy else {
            print("latency bench covers SpeechAnalyzer engines only")
            return 64
        }
        let clipCount = argumentValue("--clips", in: args).flatMap(Int.init) ?? 10
        let retentionName = argumentValue("--retention", in: args) ?? "processLifetime"
        AnalyzerSession.retention = switch retentionName {
        case "whileInUse": .whileInUse
        case "lingering": .lingering
        default: .processLifetime
        }
        let language = DictationLanguage.simplifiedChinese
        let vocabulary = Vocabulary.merged(user: [])

        let settings = AppSettings()
        let config = LLMConfig(baseURL: settings.llmBaseURL, apiKey: Keychain.readAPIKey(), model: settings.llmModel)
        let refiner = config.isConfigured && !args.contains("--no-llm")
            ? Refiner(client: OpenAICompatibleClient(config: config), vocabulary: vocabulary) : nil

        if args.contains("--llm-probe") {
            await probeLLM(config: config, vocabulary: vocabulary)
            return 0
        }

        let cases: [EvalCase]
        do {
            cases = try EvalCase.loadJSONL(String(contentsOf: corpusURL, encoding: .utf8))
                .filter { $0.kind == .mixed && $0.audio != nil }
                .prefix(clipCount).map { $0 }
        } catch {
            print("cannot read corpus: \(error)")
            return 66
        }

        var prewarmMs: Double?
        if args.contains("--prewarm") {
            let t = ContinuousClock.now
            await AnalyzerSession.prewarm(engine: engine, language: language)
            prewarmMs = ms(ContinuousClock.now - t)
        }

        var rows: [Row] = []
        var errors: [String] = []
        for c in cases {
            let url = corpusURL.deletingLastPathComponent().appendingPathComponent(c.audio!)
            do {
                let t0 = ContinuousClock.now
                let session = try await AnalyzerSession.prepare(engine: engine, language: language, vocabulary: vocabulary)
                let setup = ms(ContinuousClock.now - t0)

                var updates = 0
                var firstUpdate: Double?
                let audioStart = ContinuousClock.now
                session.onUpdate = { _ in
                    updates += 1
                    if firstUpdate == nil { firstUpdate = ms(ContinuousClock.now - audioStart) }
                }
                try await feedRealtime(url, into: session)
                let updatesDuringAudio = updates
                let tEnd = ContinuousClock.now
                let text = await session.finish()
                let finalize = ms(ContinuousClock.now - tEnd)

                var llm: Double?
                if let refiner, RefinementGate.shouldRefine(text) {
                    let t = ContinuousClock.now
                    _ = await refiner.refine(text)
                    llm = ms(ContinuousClock.now - t)
                }
                let cer = ErrorRate.cer(reference: c.reference, hypothesis: text)
                rows.append(Row(id: c.id, setup: setup, finalize: finalize, llm: llm, cer: cer, partials: updatesDuringAudio))
                print("[\(c.id)] setup=\(Int(setup))ms partials-during-audio=\(updatesDuringAudio) first-partial=\(firstUpdate.map { "\(Int($0))ms" } ?? "-") finalize=\(Int(finalize))ms cer=\(String(format: "%.1f%%", ErrorRate.cer(reference: c.reference, hypothesis: text) * 100)) llm=\(llm.map { "\(Int($0))ms" } ?? "-")")
            } catch {
                print("[\(c.id)] error: \(error)")
                errors.append("\(c.id): \(error)")
            }
        }

        var report = markdown(rows: rows, engine: engine, retention: retentionName, prewarmMs: prewarmMs, llm: refiner != nil)
        var failed = false
        if args.contains("--assert") {
            let clips = rows.map { SmokeVerdict.Clip(id: $0.id, cer: $0.cer) }
            let failures = SmokeVerdict.failures(clips: clips, errors: errors)
            failed = !failures.isEmpty
            report += failed ? "\nSMOKE: FAIL\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n" : "\nSMOKE: PASS\n"
        }
        print(report)
        if let out = argumentValue("--out", in: args) {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        return rows.isEmpty || failed ? 1 : 0
    }

    /// Reads the file in 100 ms chunks, converts to the analyzer format, and yields each chunk
    /// after 100 ms, so end-of-audio timing matches a live mic.
    static func feedRealtime(_ url: URL, into session: AnalyzerSession) async throws {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let chunkFrames = AVAudioFrameCount(source.sampleRate / 10)
        let converter = AVAudioConverter(from: source, to: session.format)
        while file.framePosition < file.length {
            let frames = min(chunkFrames, AVAudioFrameCount(file.length - file.framePosition))
            guard let chunk = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { break }
            try file.read(into: chunk, frameCount: frames) // throws (nilError) if asked to read past EOF
            if chunk.frameLength == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
            guard let converter else {
                session.yield(chunk)
                continue
            }
            let capacity = AVAudioFrameCount(Double(chunk.frameLength) * session.format.sampleRate / source.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: session.format, frameCapacity: capacity) else { break }
            let once = OnceFlag()
            nonisolated(unsafe) let input = chunk
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                guard once.claim() else {
                    status.pointee = .noDataNow
                    return nil
                }
                status.pointee = .haveData
                return input
            }
            if error == nil, out.frameLength > 0 { session.yield(out) }
        }
    }

    static func ms(_ d: Duration) -> Double { d / .milliseconds(1) }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    static func markdown(rows: [Row], engine: RecognitionEngine, retention: String, prewarmMs: Double?, llm: Bool) -> String {
        let warm = rows.dropFirst()
        let finalize = rows.map(\.finalize)
        let llms = rows.compactMap(\.llm)
        func f(_ x: Double) -> String { "\(Int(x.rounded())) ms" }
        var out = "## Latency: \(engine.displayName), retention \(retention)\(prewarmMs != nil ? ", prewarmed" : "")\n\n"
        out += "| stage | p50 | p90 |\n|---|---|---|\n"
        if let prewarmMs { out += "| prewarm (once, at launch) | \(f(prewarmMs)) | |\n" }
        if let first = rows.first { out += "| setup, first press | \(f(first.setup)) | |\n" }
        out += "| setup, later presses | \(f(percentile(warm.map(\.setup), 0.5))) | \(f(percentile(warm.map(\.setup), 0.9))) |\n"
        out += "| finalize (end of audio → text) | \(f(percentile(finalize, 0.5))) | \(f(percentile(finalize, 0.9))) |\n"
        if llm {
            out += "| LLM refinement (\(llms.count)/\(rows.count) sent by gate) | \(f(percentile(llms, 0.5))) | \(f(percentile(llms, 0.9))) |\n"
        }
        let withPartials = rows.filter { $0.partials > 0 }.count
        let meanCER = rows.isEmpty ? 0 : rows.map(\.cer).reduce(0, +) / Double(rows.count)
        out += "\nPartial results during speech on \(withPartials)/\(rows.count) clips. Mean raw CER of final text: \(String(format: "%.1f%%", meanCER * 100)).\n"
        let base = 250 + percentile(finalize, 0.5)
        out += "\nRelease → text, p50, excluding paste: \(f(base)) without LLM"
        if llm { out += ", \(f(base + percentile(llms, 0.5))) with LLM" }
        out += " (250 ms trailing capture + finalize + LLM).\n"
        return out
    }

    /// Sends one refinement request and prints timing plus the response's `usage` block (token
    /// counts, reasoning tokens if any). The API key is never printed.
    static func probeLLM(config: LLMConfig, vocabulary: [String]) async {
        guard let url = config.chatCompletionsURL else { return print("LLM not configured") }
        let system = RefinementPrompt.system(vocabulary: vocabulary)
        let variants: [(String, String, [String: Any])] = [
            ("\(config.model) default", config.model, [:]),
            ("\(config.model) thinking disabled", config.model, ["thinking": ["type": "disabled"]]),
            ("deepseek-chat", "deepseek-chat", [:]),
        ]
        for (label, model, extra) in variants {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            var body: [String: Any] = [
                "model": model, "temperature": 0, "stream": false,
                "messages": [["role": "system", "content": system],
                             ["role": "user", "content": RefinementPrompt.user("我在用 piston写一个 JSON解析器。")]],
            ]
            body.merge(extra) { $1 }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            for i in 1...3 {
                let t = ContinuousClock.now
                guard let (data, _) = try? await URLSession.shared.data(for: request) else { continue }
                let elapsed = Int(ms(ContinuousClock.now - t))
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let usage = json?["usage"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? "-"
                let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
                let hasReasoning = message?["reasoning_content"] != nil
                let content = (message?["content"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
                print("[\(label) #\(i)] \(elapsed)ms model=\(json?["model"] ?? "?") reasoning=\(hasReasoning) usage=\(usage) → \(content)")
            }
        }
    }
}
