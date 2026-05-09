import SwiftUI

// MARK: - Goose chat view

struct GooseChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    var relay: RelayClient
    @State private var inputText = ""
    @State private var showSettings = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            GooseModelBar(relay: relay)
            Divider()
            GooseMessagesView(relay: relay)
            if relay.totalTokens > 0 {
                HStack {
                    Spacer()
                    Text("\(relay.totalTokens) tokens total")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                }
            }
            Divider()
            GooseInputBar(relay: relay, inputText: $inputText, focused: _focused)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        relay.newSession()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(relay.messages.isEmpty)
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            GooseSettingsSheet(relay: relay)
        }
        .task {
            relay.connectIfNeeded()
            try? await Task.sleep(for: .seconds(1))
            await relay.listModels()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { relay.connectIfNeeded() }
        }
    }
}

// MARK: - Goose model bar

struct GooseModelBar: View {
    var relay: RelayClient
    @State private var selectedModel = ""

    var statusColor: Color {
        switch relay.status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected, .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            if relay.availableModels.isEmpty {
                Text(relay.status.label)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Spacer()
            } else {
                Picker("", selection: $selectedModel) {
                    ForEach(relay.availableModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .onChange(of: selectedModel) { _, model in
                    guard !model.isEmpty, model != relay.currentModel else { return }
                    Task { await relay.setModel(model) }
                }
                .onChange(of: relay.currentModel) { _, model in
                    if !model.isEmpty { selectedModel = model }
                }
                .onAppear {
                    if !relay.currentModel.isEmpty { selectedModel = relay.currentModel }
                    else if let first = relay.availableModels.first { selectedModel = first }
                }
            }

            Button(relay.status.isConnected ? "Disconnect" : "Connect") {
                if relay.status.isConnected { relay.disconnect() } else { relay.connect() }
            }
            .buttonStyle(.bordered)
            .tint(relay.status.isConnected ? .orange : .green)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - Goose messages

struct GooseMessagesView: View {
    var relay: RelayClient

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(relay.messages) { msg in
                        GooseMessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if relay.isProcessing, relay.messages.last?.text.isEmpty == true,
                       relay.messages.last?.toolEvents.isEmpty == true {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Thinking...").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .id("goose-thinking")
                    }
                }
                .padding()
            }
            .onChange(of: relay.messages.last?.text) {
                withAnimation(.easeOut(duration: 0.1)) {
                    if let last = relay.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: relay.messages.last?.toolEvents.count) {
                withAnimation(.easeOut(duration: 0.1)) {
                    if let last = relay.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

struct GooseMessageBubble: View {
    let message: GooseMessage
    @State private var copied = false

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isUser { Spacer(minLength: 50) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                if message.isUser {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    if !message.toolEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.toolEvents) { event in
                                HStack(spacing: 6) {
                                    Image(systemName: event.done ? "checkmark.circle.fill" : "circle.dotted")
                                        .foregroundStyle(event.done ? .green : .secondary)
                                        .font(.caption)
                                    Text(event.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
                    }

                    if !message.text.isEmpty || message.isStreaming {
                        MarkdownView(text: message.text.isEmpty ? " " : message.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
            .contextMenu {
                if !message.text.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.text
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: {
                        Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }

            if !message.isUser { Spacer(minLength: 50) }
        }
    }
}

// MARK: - Goose input bar

struct GooseInputBar: View {
    var relay: RelayClient
    @Binding var inputText: String
    @FocusState var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($focused)
                .disabled(relay.isProcessing)

            Button {
                focused = false
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                inputText = ""
                Task { await relay.sendMessage(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(canSend ? Color.accentColor : Color.gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
            && relay.status.isConnected
            && !relay.isProcessing
    }
}

// MARK: - Goose settings sheet

struct GooseSettingsSheet: View {
    var relay: RelayClient
    @Environment(\.dismiss) var dismiss
    @State private var draftURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ws://host:3284", text: $draftURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: { Text("Relay URL") } footer: {
                    Text("WebSocket address of your Goose relay service (port 3284 by default).")
                }

                if !relay.availableModels.isEmpty {
                    Section {
                        ForEach(relay.availableModels, id: \.self) { model in
                            HStack {
                                Text(model)
                                Spacer()
                                if relay.currentModel == model {
                                    Image(systemName: "checkmark").foregroundStyle(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await relay.setModel(model) } }
                        }
                    } header: { Text("Model") }
                }

                if !relay.configContent.isEmpty {
                    Section {
                        ScrollView {
                            Text(relay.configContent)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    } header: { Text("Config") }
                }

                Section {
                    Button("Save & Reconnect") {
                        relay.serverURL = draftURL
                        relay.reconnect()
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            await relay.listModels()
                            await relay.fetchConfig()
                        }
                        dismiss()
                    }
                    if relay.status.isConnected {
                        Button(role: .destructive) { relay.disconnect() } label: {
                            Text("Disconnect")
                        }
                    }
                }
            }
            .navigationTitle("Goose Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                draftURL = relay.serverURL
                Task {
                    await relay.fetchConfig()
                    await relay.listModels()
                }
            }
        }
    }
}
