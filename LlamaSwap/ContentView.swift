import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = ChatViewModel()
    @State private var showSettings = false
    @State private var showSystemPrompt = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ModelBar(vm: vm)
                Divider()
                if showSystemPrompt {
                    SystemPromptBar(text: $vm.systemPrompt)
                    Divider()
                }
                MessagesView(messages: vm.messages, isStreaming: vm.isStreaming)
                Divider()
                InputBar(vm: vm)
            }
            .navigationTitle("LlamaSwap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSystemPrompt.toggle()
                    } label: {
                        Image(systemName: showSystemPrompt ? "brain.head.profile.fill" : "brain.head.profile")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { vm.clearChat() } label: { Image(systemName: "trash") }
                            .disabled(vm.messages.isEmpty)
                        Button { showSettings = true } label: { Image(systemName: "gear") }
                    }
                }
            }
            .alert("Error", isPresented: .constant(vm.errorMessage != nil), actions: {
                Button("OK") { vm.errorMessage = nil }
            }, message: {
                Text(vm.errorMessage ?? "")
            })
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(vm: vm)
        }
        .task { await vm.fetchModels() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await vm.fetchRunning() }
            }
        }
    }
}

// MARK: - Model bar
struct ModelBar: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(vm.loadState.color)
                .frame(width: 9, height: 9)

            if vm.models.isEmpty {
                if vm.isFetchingModels {
                    ProgressView().scaleEffect(0.7)
                    Text("Connecting...").foregroundStyle(.secondary).font(.subheadline)
                } else {
                    Text("No models").foregroundStyle(.secondary).font(.subheadline)
                }
                Spacer()
            } else {
                Picker("", selection: $vm.selectedModel) {
                    ForEach(vm.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            switch vm.loadState {
            case .loading:
                ProgressView().scaleEffect(0.8)
                    .frame(width: 60)
            case .loaded:
                Button("Unload") { Task { await vm.unloadModel() } }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
            case .unloaded:
                Button("Load") { Task { await vm.loadModel() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.models.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - System prompt
struct SystemPromptBar: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("System Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            TextEditor(text: $text)
                .frame(minHeight: 70, maxHeight: 120)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .scrollContentBackground(.hidden)
        }
        .background(Color(.secondarySystemBackground))
    }
}

// MARK: - Messages
struct MessagesView: View {
    let messages: [ChatMessage]
    let isStreaming: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                    if isStreaming, messages.last?.content.isEmpty == true {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Thinking...").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .id("thinking")
                    }
                }
                .padding()
            }
            .onChange(of: messages.last?.content) {
                withAnimation(.easeOut(duration: 0.1)) {
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: isStreaming) {
                if isStreaming { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isUser { Spacer(minLength: 50) }
            Text(message.content.isEmpty ? " " : message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.isUser ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(message.isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            if !message.isUser { Spacer(minLength: 50) }
        }
    }
}

// MARK: - Input bar
struct InputBar: View {
    @Bindable var vm: ChatViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message...", text: $vm.inputText, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($focused)
                .disabled(vm.isStreaming)

            Button {
                focused = false
                Task { await vm.sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty || vm.loadState != .loaded ? Color.gray : Color.accentColor)
            }
            .disabled(vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty || vm.loadState != .loaded || vm.isStreaming)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Settings
struct SettingsSheet: View {
    @Bindable var vm: ChatViewModel
    @Environment(\.dismiss) var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://host:8081", text: $draft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Server URL")
                } footer: {
                    Text("The address of your llama-swap instance.")
                }
                Section {
                    Button("Save & Reconnect") {
                        vm.serverURL = draft
                        Task { await vm.fetchModels() }
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { draft = vm.serverURL }
        }
    }
}
