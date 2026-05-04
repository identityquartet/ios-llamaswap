import Foundation
import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var content: String
    var isUser: Bool { role == "user" }
}

struct TokenUsage {
    let promptTokens: Int
    let completionTokens: Int
}

@Observable
class ChatViewModel {
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: "defaultModel") }
    }
    var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: "temperature") }
    }
    var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: "maxTokens") }
    }

    var models: [String] = []
    var runningModels: Set<String> = []
    var selectedModel: String = "" {
        didSet { loadState = runningModels.contains(selectedModel) ? .loaded : .unloaded }
    }
    var systemPrompt: String = "" {
        didSet { Keychain.save(systemPrompt, key: "systemPrompt") }
    }
    var presets: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(presets) {
                UserDefaults.standard.set(data, forKey: "systemPromptPresets")
            }
        }
    }

    var messages: [ChatMessage] = []
    var inputText: String = ""
    var isStreaming = false
    var loadState: LoadState = .unloaded
    var loadingStartTime: Date?
    var errorMessage: String?
    var isFetchingModels = false
    var tokenUsage: TokenUsage?

    private var streamTask: Task<Void, Never>?

    enum LoadState {
        case unloaded, loading, loaded
        var color: Color {
            switch self {
            case .unloaded: return .orange
            case .loading:  return .yellow
            case .loaded:   return .green
            }
        }
        var label: String {
            switch self {
            case .unloaded: return "Unloaded"
            case .loading:  return "Loading..."
            case .loaded:   return "Loaded"
            }
        }
    }

    init() {
        serverURL    = UserDefaults.standard.string(forKey: "serverURL") ?? "http://192.168.8.117:8081"
        defaultModel = UserDefaults.standard.string(forKey: "defaultModel") ?? ""
        temperature  = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 0.7
        maxTokens    = UserDefaults.standard.object(forKey: "maxTokens") as? Int ?? 0
        systemPrompt = Keychain.load(key: "systemPrompt") ?? ""

        if let data = UserDefaults.standard.data(forKey: "systemPromptPresets"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            presets = decoded
        } else {
            presets = [:]
        }
    }

    // MARK: - Server

    func fetchModels() async {
        await MainActor.run { isFetchingModels = true; errorMessage = nil }
        defer { Task { @MainActor in isFetchingModels = false } }
        guard let url = URL(string: "\(serverURL)/v1/models") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Decodable { struct M: Decodable { let id: String }; let data: [M] }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            let ids = resp.data.map { $0.id }.sorted()
            await MainActor.run {
                models = ids
                if !ids.contains(selectedModel) {
                    selectedModel = (!defaultModel.isEmpty && ids.contains(defaultModel))
                        ? defaultModel : (ids.first ?? "")
                }
            }
        } catch {
            await MainActor.run { errorMessage = "Cannot reach server: \(error.localizedDescription)" }
        }
        await fetchRunning()
    }

    func fetchRunning() async {
        guard let url = URL(string: "\(serverURL)/running") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        struct Resp: Decodable { struct R: Decodable { let model: String }; let running: [R] }
        guard let resp = try? JSONDecoder().decode(Resp.self, from: data) else { return }
        let names = Set(resp.running.map { $0.model })
        await MainActor.run {
            runningModels = names
            guard loadState != .loading else { return }
            if let running = names.first(where: { models.contains($0) }) {
                selectedModel = running; loadState = .loaded
            } else {
                if !defaultModel.isEmpty && models.contains(defaultModel) { selectedModel = defaultModel }
                loadState = .unloaded
            }
        }
    }

    func loadModel() async {
        await MainActor.run { loadState = .loading; loadingStartTime = Date() }
        let bgTask = BGTaskHandle(); bgTask.begin(name: "LlamaLoad")
        defer { bgTask.end() }

        let modelToLoad = selectedModel

        // Fire the completions request to trigger llama-swap to start loading the model.
        // We don't await it — the /running poll below is the source of truth for readiness.
        if let url = URL(string: "\(serverURL)/v1/chat/completions") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 360
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": modelToLoad,
                "messages": [["role": "user", "content": "hi"]],
                "max_tokens": 1, "stream": false
            ])
            Task { _ = try? await URLSession.shared.data(for: req) }
        }

        // Poll /running every 3s until the model is confirmed loaded (5-minute timeout).
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            let stillLoading = await MainActor.run { loadState == .loading }
            guard stillLoading else { return }

            guard let url = URL(string: "\(serverURL)/running"),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { continue }
            struct Resp: Decodable { struct R: Decodable { let model: String }; let running: [R] }
            guard let resp = try? JSONDecoder().decode(Resp.self, from: data) else { continue }
            let names = Set(resp.running.map { $0.model })
            if names.contains(modelToLoad) {
                await MainActor.run {
                    runningModels = names
                    loadState = .loaded
                    loadingStartTime = nil
                }
                return
            }
        }

        await MainActor.run {
            loadState = .unloaded
            loadingStartTime = nil
            errorMessage = "Model took too long to load"
        }
    }

    func unloadModel() async {
        guard let url = URL(string: "\(serverURL)/api/models/unload/\(selectedModel)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: req)
        await MainActor.run { runningModels.remove(selectedModel); loadState = .unloaded }
    }

    // MARK: - Chat

    func stopStreaming() {
        streamTask?.cancel()
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        if loadState != .loaded {
            await loadModel()
            guard loadState == .loaded else { return }
        }

        await MainActor.run { messages.append(ChatMessage(role: "user", content: text)); inputText = "" }

        await streamResponse()
    }

    func regenerateLastResponse() async {
        guard !isStreaming, messages.last?.isUser == false, messages.count >= 2 else { return }

        await MainActor.run { messages.removeLast() }

        await streamResponse()
    }

    private func streamResponse() async {
        await MainActor.run {
            messages.append(ChatMessage(role: "assistant", content: ""))
            isStreaming = true
            tokenUsage = nil
        }

        var apiMessages: [[String: String]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        for msg in messages.dropLast() {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        let bgTask = BGTaskHandle(); bgTask.begin(name: "LlamaChat")

        streamTask = Task {
            defer { Task { @MainActor in isStreaming = false }; bgTask.end() }

            guard let url = URL(string: "\(serverURL)/v1/chat/completions") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 300

            var body: [String: Any] = [
                "model": selectedModel,
                "messages": apiMessages,
                "stream": true,
                "stream_options": ["include_usage": true],
                "temperature": temperature,
            ]
            if maxTokens > 0 { body["max_tokens"] = maxTokens }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (stream, _) = try await URLSession.shared.bytes(for: req)
                struct Chunk: Decodable {
                    struct Choice: Decodable {
                        struct Delta: Decodable { let content: String? }
                        let delta: Delta
                    }
                    let choices: [Choice]
                    struct Usage: Decodable { let prompt_tokens: Int; let completion_tokens: Int }
                    let usage: Usage?
                }
                for try await line in stream.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data: "), line != "data: [DONE]",
                          let data = line.dropFirst(6).data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(Chunk.self, from: data)
                    else { continue }
                    if let content = chunk.choices.first?.delta.content {
                        await MainActor.run { messages[messages.count - 1].content += content }
                    }
                    if let u = chunk.usage {
                        await MainActor.run {
                            tokenUsage = TokenUsage(promptTokens: u.prompt_tokens,
                                                    completionTokens: u.completion_tokens)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        messages[messages.count - 1].content = "Error: \(error.localizedDescription)"
                    }
                }
            }

        }

        await streamTask?.value
    }

    func clearChat() {
        messages = []
        tokenUsage = nil
    }
}
