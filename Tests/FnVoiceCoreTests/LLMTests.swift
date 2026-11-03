import Foundation
import Testing
@testable import FnVoiceCore

/// Runs Tests/MockLLM/server.py once for the whole test process.
final class MockLLMServer: Sendable {
    static let shared = MockLLMServer()

    let process: Process
    let port: Int

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    private init() {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MockLLM/server.py")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, "--port", "0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try! p.run()
        var line = Data()
        while true {
            let byte = out.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { break }
            line.append(byte)
        }
        process = p
        port = Int(String(decoding: line, as: UTF8.self)) ?? 0
        precondition(port > 0, "mock LLM server failed to start")
    }

    func client(model: String, key: String = "test-key", timeout: Duration = .seconds(5)) -> OpenAICompatibleClient {
        OpenAICompatibleClient(config: LLMConfig(baseURL: baseURL, apiKey: key, model: model), timeout: timeout)
    }

    func lastRequest() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/last")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

@Suite struct LLMConfigTests {
    @Test func chatCompletionsURLNormalization() {
        func url(_ base: String) -> String? { LLMConfig(baseURL: base, apiKey: "", model: "m").chatCompletionsURL?.absoluteString }
        #expect(url("https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions")
        #expect(url(" https://api.openai.com/v1/ ") == "https://api.openai.com/v1/chat/completions")
        #expect(url("http://localhost:11434/v1/chat/completions") == "http://localhost:11434/v1/chat/completions")
        #expect(url("") == nil)
        #expect(url("api.openai.com/v1") == nil)
        #expect(url("ftp://example.com") == nil)
    }

    @Test func apiKeyIsOptionalButModelIsNot() {
        #expect(LLMConfig(baseURL: "http://localhost:11434/v1", apiKey: "", model: "qwen2.5").isConfigured)
        #expect(!LLMConfig(baseURL: "http://localhost:11434/v1", apiKey: "k", model: "  ").isConfigured)
        #expect(!LLMConfig(baseURL: "", apiKey: "k", model: "m").isConfigured)
    }

    @Test func parsesOpenAIResponseShape() throws {
        let ok = #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#
        #expect(try OpenAICompatibleClient.parseContent(Data(ok.utf8)) == "hi")
        #expect(throws: LLMError.malformed) { try OpenAICompatibleClient.parseContent(Data("{}".utf8)) }
        let empty = #"{"choices":[{"message":{"content":"  "}}]}"#
        #expect(throws: LLMError.emptyResponse) { try OpenAICompatibleClient.parseContent(Data(empty.utf8)) }
    }
}

@Suite(.serialized) struct OpenAIClientAgainstMockServerTests {
    let server = MockLLMServer.shared

    @Test func successfulCompletion() async throws {
        let out = try await server.client(model: "fix").complete(system: "s", user: RefinementPrompt.user("我用配森"))
        #expect(out == "我用Python")
    }

    @Test func requestIsDeterministicAndCarriesPromptAndKey() async throws {
        _ = try await server.client(model: "echo").complete(system: RefinementPrompt.system, user: RefinementPrompt.user("你好"))
        let last = try await server.lastRequest()
        let headers = last["headers"] as! [String: String]
        let body = last["body"] as! [String: Any]
        #expect(headers["authorization"] == "Bearer test-key")
        #expect((body["temperature"] as? NSNumber)?.doubleValue == 0)
        let messages = body["messages"] as! [[String: String]]
        #expect(messages[0]["role"] == "system" && messages[0]["content"] == RefinementPrompt.system)
        #expect(messages[1]["content"] == "<transcript>\n你好\n</transcript>")
    }

    @Test func emptyKeySendsNoAuthorizationHeader() async throws {
        await #expect(throws: LLMError.unauthorized(401)) {
            try await server.client(model: "echo", key: "").complete(system: "s", user: "u")
        }
        let headers = try await server.lastRequest()["headers"] as! [String: String]
        #expect(headers["authorization"] == nil)
    }

    @Test func wrongKeyIsUnauthorized() async {
        await #expect(throws: LLMError.unauthorized(401)) {
            try await server.client(model: "echo", key: "nope").complete(system: "s", user: "u")
        }
    }

    @Test func slowServerHitsHardTimeout() async {
        let start = ContinuousClock.now
        await #expect(throws: LLMError.timeout) {
            try await server.client(model: "slow", timeout: .milliseconds(800)).complete(system: "s", user: "u")
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func nonJSONBodyIsMalformed() async {
        await #expect(throws: LLMError.malformed) {
            try await server.client(model: "malformed").complete(system: "s", user: "u")
        }
    }

    @Test func serverErrorIsReported() async {
        await #expect(throws: LLMError.http(500)) {
            try await server.client(model: "http500").complete(system: "s", user: "u")
        }
    }

    @Test func unreachableServerIsNetworkError() async {
        let client = OpenAICompatibleClient(config: LLMConfig(baseURL: "http://127.0.0.1:9/v1", apiKey: "", model: "m"))
        do {
            _ = try await client.complete(system: "s", user: "u")
            Issue.record("expected failure")
        } catch let e as LLMError {
            if case .network = e {} else { Issue.record("expected network error, got \(e)") }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // End-to-end through Refiner: every failure mode must still yield the user's words.

    @Test func refinerAppliesConservativeFix() async {
        let out = await Refiner(client: server.client(model: "fix")).refine("我在用配森写一个杰森解析器")
        #expect(out == RefineOutcome(text: "我在用Python写一个JSON解析器", usedLLM: true, fallbackReason: nil))
    }

    @Test func refinerUnwrapsDecoratedOutput() async {
        let out = await Refiner(client: server.client(model: "wrapped")).refine("配森很好用")
        #expect(out.text == "Python很好用")
        #expect(out.usedLLM)
    }

    @Test func refinerRejectsRewrite() async {
        let raw = "今天下午三点开会讨论一下接口设计"
        let out = await Refiner(client: server.client(model: "rewrite")).refine(raw)
        #expect(out.text == raw)
        #expect(!out.usedLLM)
        #expect(out.fallbackReason?.hasPrefix("guardrail") == true)
    }

    @Test func refinerFallsBackOnTimeoutMalformedAndAuth() async {
        for client in [server.client(model: "slow", timeout: .milliseconds(500)),
                       server.client(model: "malformed"),
                       server.client(model: "echo", key: "bad")] {
            let out = await Refiner(client: client).refine("原文")
            #expect(out.text == "原文")
            #expect(!out.usedLLM)
        }
    }
}
