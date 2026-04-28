import Foundation
import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var content: String
    var isUser: Bool { role == "user" }
}

@Observable
class ChatViewModel {
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var models: [String] = []
    var runningModels: Set<String> = []
    var selectedModel: String = "" {
        didSet { loadState = runningModels.contains(selectedModel) ? .loaded : .unloaded }
    }
    var systemPrompt: String = "" {
        didSet { Keychain.save(systemPrompt, key: "systemPrompt") }
    }
    var messages: [ChatMessage] = []
    var inputText: String = ""
    var isStreaming = false
    var loadState: LoadState = .unloaded
    var errorMessage: String?
    var isFetchingModels = false

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
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "http://192.168.8.117:8081"
        systemPrompt = Keychain.load(key: "systemPrompt") ?? ""
    }

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
                if !ids.contains(selectedModel), let first = ids.first { selectedModel = first }
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
            if let running = names.first(where: { models.contains($0) }) {
                selectedModel = running
                loadState = .loaded
            } else {
                loadState = runningModels.contains(selectedModel) ? .loaded : .unloaded
            }
        }
    }

    func loadModel() async {
        await MainActor.run { loadState = .loading }
        guard let url = URL(string: "\(serverURL)/v1/chat/completions") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": selectedModel,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
            "stream": false
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            await MainActor.run {
                loadState = ok ? .loaded : .unloaded
                if ok { runningModels.insert(selectedModel) }
            }
        } catch {
            await MainActor.run { loadState = .unloaded; errorMessage = error.localizedDescription }
        }
    }

    func unloadModel() async {
        guard let url = URL(string: "\(serverURL)/api/models/unload/\(selectedModel)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: req)
        await MainActor.run {
            runningModels.remove(selectedModel)
            loadState = .unloaded
        }
    }

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        await MainActor.run {
            messages.append(ChatMessage(role: "user", content: text))
            messages.append(ChatMessage(role: "assistant", content: ""))
            inputText = ""
            isStreaming = true
        }

        var apiMessages: [[String: String]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        for msg in messages.dropLast() {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        guard let url = URL(string: "\(serverURL)/v1/chat/completions") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": selectedModel,
            "messages": apiMessages,
            "stream": true
        ])

        do {
            let (stream, _) = try await URLSession.shared.bytes(for: req)
            struct Chunk: Decodable {
                struct Choice: Decodable {
                    struct Delta: Decodable { let content: String? }
                    let delta: Delta
                }
                let choices: [Choice]
            }
            for try await line in stream.lines {
                guard line.hasPrefix("data: "), line != "data: [DONE]",
                      let data = line.dropFirst(6).data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(Chunk.self, from: data),
                      let content = chunk.choices.first?.delta.content
                else { continue }
                await MainActor.run { messages[messages.count - 1].content += content }
            }
        } catch {
            await MainActor.run {
                messages[messages.count - 1].content = "Error: \(error.localizedDescription)"
            }
        }
        await MainActor.run { isStreaming = false }
    }

    func clearChat() { messages = [] }
}
