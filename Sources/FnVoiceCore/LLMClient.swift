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
    private let session: URLSession

    public init(config: LLMConfig, timeout: Duration = .seconds(4), session: URLSession? = nil) {
        self.config = config
        self.timeout = timeout
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func complete(system: String, user: String) async throws -> String {
        guard let url = config.chatCompletionsURL else { throw LLMError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespaces),
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = self.session
        let timeout = self.timeout
        let finalRequest = request
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                do {
                    return try await session.data(for: finalRequest)
                } catch let e as URLError where e.code == .timedOut {
                    throw LLMError.timeout
                } catch let e as URLError where e.code == .cancelled {
                    throw CancellationError()
                } catch let e as URLError {
                    throw LLMError.network(e.localizedDescription)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LLMError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LLMError.timeout }
            return first
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.malformed }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw LLMError.unauthorized(http.statusCode)
        default: throw LLMError.http(http.statusCode)
        }
        return try Self.parseContent(data)
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
