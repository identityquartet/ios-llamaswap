import Foundation

@MainActor
@Observable
final class RelayClient {
    enum ConnectionStatus {
        case disconnected, connecting, connected, error(String)
        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .error(let m): return "Error: \(m)"
            }
        }
        var isConnected: Bool { if case .connected = self { return true }; return false }
        var isConnecting: Bool { if case .connecting = self { return true }; return false }
    }

    var status: ConnectionStatus = .disconnected
    var messages: [GooseMessage] = []
    var isProcessing = false
    var sessionStarted = false
    var configContent: String = ""
    var totalTokens: Int = 0
    var availableModels: [String] = []
    var currentModel: String = ""

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "relayURL") ?? "ws://192.168.8.117:3284" }
        set { UserDefaults.standard.set(newValue, forKey: "relayURL") }
    }

    private var webSocket: URLSessionWebSocketTask?
    private let urlSession = URLSession.shared
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    func connectIfNeeded() {
        guard !status.isConnected, !status.isConnecting else { return }
        connect()
    }

    func connect() {
        receiveTask?.cancel(); pingTask?.cancel(); retryTask?.cancel()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        guard let url = URL(string: serverURL) else { status = .error("Invalid URL"); return }
        status = .connecting
        let ws = urlSession.webSocketTask(with: url)
        webSocket = ws
        ws.resume()
        status = .connected
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        pingTask = Task { [weak self] in await self?.pingLoop() }
    }

    func disconnect() {
        receiveTask?.cancel(); pingTask?.cancel(); retryTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        status = .disconnected
        isProcessing = false
    }

    func reconnect() {
        disconnect()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.connect()
        }
    }

    func sendMessage(_ text: String) async {
        guard status.isConnected, !isProcessing else { return }
        messages.append(GooseMessage(role: .user, text: text))
        messages.append(GooseMessage(role: .assistant, text: "", isStreaming: true))
        isProcessing = true
        let payload: [String: Any] = [
            "type": "message", "text": text,
            "session": "ios-default", "resume": sessionStarted
        ]
        sessionStarted = true
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { isProcessing = false; return }
        do {
            try await webSocket?.send(.string(str))
        } catch {
            let li = messages.count - 1
            if li >= 0 { messages[li].text = "⚠️ Send failed"; messages[li].isStreaming = false }
            isProcessing = false
        }
    }

    func fetchConfig() async {
        guard status.isConnected else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "get_config"]),
              let str = String(data: data, encoding: .utf8) else { return }
        try? await webSocket?.send(.string(str))
    }

    func listModels() async {
        guard status.isConnected else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "list_models"]),
              let str = String(data: data, encoding: .utf8) else { return }
        try? await webSocket?.send(.string(str))
    }

    func setModel(_ model: String) async {
        guard status.isConnected else { return }
        let payload: [String: Any] = ["type": "set_model", "model": model]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        try? await webSocket?.send(.string(str))
    }

    func newSession() {
        sessionStarted = false
        messages.removeAll()
        totalTokens = 0
    }

    private func scheduleRetry() {
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let ws = webSocket else { break }
            do {
                let msg = try await ws.receive()
                switch msg {
                case .string(let t): handleEvent(t)
                case .data(let d): handleEvent(String(data: d, encoding: .utf8) ?? "")
                @unknown default: break
                }
            } catch {
                status = .disconnected; isProcessing = false
                scheduleRetry()
                break
            }
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard status.isConnected else { break }
            webSocket?.sendPing { _ in }
        }
    }

    private func handleEvent(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let li = messages.count - 1
        switch type {
        case "token":
            guard li >= 0 else { return }
            messages[li].text += obj["text"] as? String ?? ""
        case "tool":
            guard li >= 0 else { return }
            let action = obj["action"] as? String ?? ""
            if action == "start" {
                let name = obj["name"] as? String ?? "tool"
                let input = obj["input"] as? String ?? ""
                messages[li].toolEvents.append(ToolEvent(name: name, input: input))
            } else if action == "end", !messages[li].toolEvents.isEmpty {
                messages[li].toolEvents[messages[li].toolEvents.count - 1].done = true
            }
        case "done":
            guard li >= 0 else { return }
            messages[li].isStreaming = false
            isProcessing = false
            totalTokens += obj["tokens"] as? Int ?? 0
        case "error":
            guard li >= 0 else { return }
            messages[li].text = "⚠️ \(obj["text"] as? String ?? "Error")"
            messages[li].isStreaming = false
            isProcessing = false
        case "models":
            availableModels = obj["models"] as? [String] ?? []
            if let c = obj["current"] as? String, !c.isEmpty { currentModel = c }
        case "model_set":
            if let m = obj["model"] as? String { currentModel = m }
        case "config":
            configContent = obj["content"] as? String ?? ""
        default: break
        }
    }
}
