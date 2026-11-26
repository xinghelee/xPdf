import Foundation
import Security

enum AIProvider: String, CaseIterable, Identifiable {
    case claude, openAI, deepSeek
    var id: Self { self }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        }
    }

    /// Where to create an API key.
    var keyPage: URL {
        switch self {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }

    fileprivate var baseURL: URL {
        switch self {
        case .claude: URL(string: "https://api.anthropic.com/v1/")!
        case .openAI: URL(string: "https://api.openai.com/v1/")!
        case .deepSeek: URL(string: "https://api.deepseek.com/")!
        }
    }

    /// Picked as the default model when the account offers them, in this order.
    fileprivate var preferredModels: [String] {
        switch self {
        case .claude: ["claude-sonnet-5-5", "claude-opus-5-5"]
        case .openAI: []
        case .deepSeek: ["deepseek-v4-flash", "deepseek-v4-pro", "deepseek-chat"]
        }
    }

    /// How much document text (in characters) is sent with each question.
    var documentBudget: Int {
        switch self {
        case .claude, .openAI: 400_000
        case .deepSeek: 150_000
        }
    }
}

// MARK: - Settings

/// API keys (in the keychain), chosen models and each provider's model list.
@Observable
final class AISettings {
    static let shared = AISettings()

    var provider: AIProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "ai.provider") }
    }
    private(set) var keys: [AIProvider: String] = [:]
    private(set) var models: [AIProvider: String] = [:]
    private(set) var availableModels: [AIProvider: [String]] = [:]
    private(set) var loading: Set<AIProvider> = []
    private(set) var errors: [AIProvider: String] = [:]

    private init() {
        provider = UserDefaults.standard.string(forKey: "ai.provider").flatMap(AIProvider.init) ?? .claude
        for provider in AIProvider.allCases {
            keys[provider] = Keychain.read(provider.rawValue)
            models[provider] = UserDefaults.standard.string(forKey: "ai.model.\(provider.rawValue)")
        }
    }

    func key(for provider: AIProvider) -> String { keys[provider] ?? "" }
    func model(for provider: AIProvider) -> String { models[provider] ?? "" }

    func isReady(_ provider: AIProvider) -> Bool {
        !key(for: provider).isEmpty && !model(for: provider).isEmpty
    }

    func setKey(_ key: String, for provider: AIProvider) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != self.key(for: provider) else { return }
        keys[provider] = key.isEmpty ? nil : key
        Keychain.write(key.isEmpty ? nil : key, for: provider.rawValue)
        availableModels[provider] = nil
        errors[provider] = nil
        if key.isEmpty {
            setModel("", for: provider)
        } else {
            Task { await refreshModels(for: provider) }
        }
    }

    func setModel(_ model: String, for provider: AIProvider) {
        models[provider] = model.isEmpty ? nil : model
        UserDefaults.standard.set(model.isEmpty ? nil : model, forKey: "ai.model.\(provider.rawValue)")
    }

    @MainActor
    func refreshModels(for provider: AIProvider) async {
        let key = key(for: provider)
        guard !key.isEmpty, !loading.contains(provider) else { return }
        loading.insert(provider)
        defer { loading.remove(provider) }
        do {
            let list = try await AIClient.listModels(provider: provider, key: key)
            guard self.key(for: provider) == key else { return }
            availableModels[provider] = list
            errors[provider] = list.isEmpty ? "这个账户没有可用的对话模型。" : nil
            let current = model(for: provider)
            if current.isEmpty || !list.contains(current) {
                setModel(provider.preferredModels.first(where: list.contains) ?? list.first ?? "", for: provider)
            }
        } catch {
            guard self.key(for: provider) == key else { return }
            errors[provider] = error.localizedDescription
        }
    }
}

enum Keychain {
    private static let service = "com.xinghelee.xPdf.ai"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, for account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrLabel] = "xPdf AI API Key"
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - API

struct AIMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let content: String
}

enum AIError: LocalizedError {
    case http(Int, String?)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            let detail = message.map { "：\($0)" } ?? ""
            switch status {
            case 401, 403: return "API Key 无效或没有权限\(detail)"
            case 402: return "账户余额不足\(detail)"
            case 404: return "找不到这个模型\(detail)"
            case 429: return "请求太频繁或额度已用完\(detail)"
            case 500...: return "服务暂时不可用（\(status)）\(detail)"
            default: return "请求失败（\(status)）\(detail)"
            }
        case .network(let message): return "网络错误：\(message)"
        }
    }
}

enum AIClient {
    private static func request(_ provider: AIProvider, path: String, key: String) -> URLRequest {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent(path))
        switch provider {
        case .claude:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI, .deepSeek:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Chat models the key can use, newest first where the API says so.
    static func listModels(provider: AIProvider, key: String) async throws -> [String] {
        var request = request(provider, path: "models", key: key)
        if provider == .claude {
            request.url = URL(string: request.url!.absoluteString + "?limit=100")
        }
        let (data, response) = try await load(request)
        try check(response, data)
        struct Entry: Decodable { let id: String; let created: Int? }
        struct List: Decodable { let data: [Entry] }
        var entries = try JSONDecoder().decode(List.self, from: data).data
        if provider == .openAI {
            // The list includes embedding, audio, image and other non-chat models.
            let excluded = ["audio", "realtime", "tts", "transcribe", "image", "search", "embedding",
                            "moderation", "instruct", "codex", "computer-use", "dall-e", "whisper", "babbage", "davinci"]
            entries = entries.filter { entry in
                let id = entry.id.lowercased()
                let chat = id.hasPrefix("gpt-") || id.range(of: #"^o\d"#, options: .regularExpression) != nil
                return chat && !excluded.contains(where: id.contains)
            }
            entries.sort { ($0.created ?? 0) > ($1.created ?? 0) }
        }
        return entries.map(\.id)
    }

    /// Streams the reply text. `system` is sent as the system prompt; `document` (if any) follows it
    /// as a separate block so providers can cache it across turns.
    static func stream(provider: AIProvider, key: String, model: String, system: String, document: String,
                       messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request: URLRequest
                    var body: [String: Any]
                    switch provider {
                    case .claude:
                        request = self.request(provider, path: "messages", key: key)
                        var systemBlocks: [[String: Any]] = [["type": "text", "text": system]]
                        if !document.isEmpty {
                            systemBlocks.append(["type": "text", "text": document, "cache_control": ["type": "ephemeral"]])
                        }
                        body = [
                            "model": model, "max_tokens": 8192, "stream": true, "system": systemBlocks,
                            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        ]
                    case .openAI, .deepSeek:
                        request = self.request(provider, path: "chat/completions", key: key)
                        let systemText = document.isEmpty ? system : system + "\n\n" + document
                        body = [
                            "model": model, "stream": true,
                            "messages": [["role": "system", "content": systemText]]
                                + messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        ]
                    }
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    request.timeoutInterval = 300

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                    } catch {
                        throw AIError.network(error.localizedDescription)
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte); if data.count > 64_000 { break } }
                        throw AIError.http(http.statusCode, errorMessage(in: data))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let message = (json["error"] as? [String: Any])?["message"] as? String {
                            throw AIError.http(500, message)
                        }
                        if let text = deltaText(in: json, provider: provider), !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func deltaText(in json: [String: Any], provider: AIProvider) -> String? {
        switch provider {
        case .claude:
            guard json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        case .openAI, .deepSeek:
            let choice = (json["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        }
    }

    private static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw AIError.network(error.localizedDescription)
        }
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.http(http.statusCode, errorMessage(in: data))
        }
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        if let error = json["error"] as? [String: Any] { return error["message"] as? String }
        return json["message"] as? String
    }
}
