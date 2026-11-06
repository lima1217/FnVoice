import Foundation

public struct LLMConfig: Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String

    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    /// The API key is optional: local OpenAI-compatible servers (Ollama, LM Studio) don't need one.
    public var isConfigured: Bool {
        chatCompletionsURL != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isDeepSeek: Bool {
        chatCompletionsURL?.host?.lowercased().hasSuffix("deepseek.com") ?? false
    }

    /// Accepts `https://host/v1`, `https://host/v1/`, or a full `.../chat/completions` URL.
    public var chatCompletionsURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.hasSuffix("/chat/completions") { s += "/chat/completions" }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}

public enum LLMError: Error, Equatable, Sendable {
    case badURL
    case unauthorized(Int)
    case http(Int)
    case timeout
    case network(String)
    case malformed
    case emptyResponse

    public var userMessage: String {
        switch self {
        case .badURL: "Invalid API Base URL"
        case .unauthorized(let code): "Unauthorized (HTTP \(code)) — check the API key"
        case .http(let code): "Server error (HTTP \(code)) — check the model name and URL"
        case .timeout: "Timed out"
        case .network(let msg): "Network error: \(msg)"
        case .malformed: "Unexpected response (not OpenAI-compatible JSON)"
        case .emptyResponse: "Model returned an empty response"
        }
    }
}

public protocol LLMClient: Sendable {
    func complete(system: String, user: String) async throws -> String
}

public struct OpenAICompatibleClient: LLMClient {
    public let config: LLMConfig
    /// Hard limit on the whole request, not URLSession's idle timeout.
    public let timeout: Duration
    /// If no reply arrives by then, an identical second request races the first. DeepSeek answers
    /// in ~1.3 s, but about 1 call in 40 takes 4–12 s; the duplicate usually lands in ~1.3 s more.
    public let hedgeAfter: Duration?
    private let session: URLSession

    public init(
        config: LLMConfig, timeout: Duration = .seconds(4), hedgeAfter: Duration? = .seconds(2),
        session: URLSession? = nil
    ) {
        self.config = config
        self.timeout = timeout
        self.hedgeAfter = hedgeAfter
        self.session = session ?? Self.sharedSession
    }

    /// One session for the app's lifetime keeps the HTTPS connection alive between dictations; a
    /// new session per request paid DNS + TLS each time and pushed some calls past the timeout.
    static let sharedSession = URLSession(configuration: .ephemeral)

    private enum Attempt: Sendable {
        case reply(Data, URLResponse)
        case failed(Error)
        case hedge
        case deadline
    }

    public func complete(system: String, user: String) async throws -> String {
        guard let url = config.chatCompletionsURL else { throw LLMError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(config: config, system: system, user: user))

        let session = self.session
        let finalRequest = request
        @Sendable func send() async -> Attempt {
            do {
                let (data, response) = try await session.data(for: finalRequest)
                return .reply(data, response)
            } catch let e as URLError where e.code == .timedOut {
                return .failed(LLMError.timeout)
            } catch let e as URLError where e.code == .cancelled {
                return .failed(CancellationError())
            } catch let e as URLError {
                return .failed(LLMError.network(e.localizedDescription))
            } catch {
                return .failed(error)
            }
        }

        let timeout = self.timeout
        let hedgeAfter = self.hedgeAfter
        let (data, response) = try await withThrowingTaskGroup(of: Attempt.self) { group in
            group.addTask { await send() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .deadline
            }
            if let hedgeAfter, hedgeAfter < timeout {
                group.addTask {
                    try await Task.sleep(for: hedgeAfter)
                    return .hedge
                }
            }
            defer { group.cancelAll() }
            var inFlight = 1
            var firstError: Error?
            while let attempt = try await group.next() {
                switch attempt {
                case .reply(let data, let response):
                    return (data, response)
                case .hedge:
                    group.addTask { await send() }
                    inFlight += 1
                case .failed(let error):
                    inFlight -= 1
                    firstError = firstError ?? error
                    if inFlight == 0 { throw error }
                case .deadline:
                    throw LLMError.timeout
                }
            }
            throw firstError ?? LLMError.timeout
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.malformed }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw LLMError.unauthorized(http.statusCode)
        default: throw LLMError.http(http.statusCode)
        }
        return try Self.parseContent(data)
    }

    static func requestBody(config: LLMConfig, system: String, user: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespaces),
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        // DeepSeek's hybrid models think by default: 200–800 hidden tokens and 3–6 s for a
        // ~10-token correction, versus ~1 s without. Other providers reject unknown fields,
        // so this is only sent to DeepSeek.
        if config.isDeepSeek { body["thinking"] = ["type": "disabled"] }
        return body
    }

    static func parseContent(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw LLMError.malformed }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw LLMError.emptyResponse }
        return content
    }
}
