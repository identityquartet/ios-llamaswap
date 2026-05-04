import SwiftUI
import UIKit

// MARK: - Root

struct RootView: View {
    var body: some View {
        NavigationStack {
            ChatView()
        }
    }
}

// MARK: - Chat view

struct ChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm = ChatViewModel()
    @State private var showSettings = false
    @State private var showSystemPrompt = false
    @State private var showClearConfirm = false
    @State private var showPresetSave = false
    @State private var newPresetName = ""

    var body: some View {
        VStack(spacing: 0) {
            ModelBar(vm: vm)
            Divider()
            if let error = vm.errorMessage {
                ErrorBanner(message: error) { vm.errorMessage = nil }
                Divider()
            }
            if showSystemPrompt {
                SystemPromptBar(vm: vm,
                                showPresetSave: $showPresetSave,
                                newPresetName: $newPresetName)
                Divider()
            }
            MessagesView(vm: vm)
            if let usage = vm.tokenUsage {
                HStack {
                    Spacer()
                    Text("\(usage.promptTokens) in · \(usage.completionTokens) out · \(String(format: "%.1f", usage.tokensPerSecond)) tok/s")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                }
            }
            Divider()
            InputBar(vm: vm)
        }
        .navigationTitle("New Chat")
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
                    Button { Task { await vm.fetchModels() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isFetchingModels)
                    Button { showClearConfirm = true } label: { Image(systemName: "trash") }
                        .disabled(vm.messages.isEmpty)
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
            }
        }
        .confirmationDialog("Clear all messages?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { vm.clearChat() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(vm: vm)
        }
        .task { await vm.fetchModels() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vm.fetchRunning() } }
        }
    }
}

// MARK: - Error banner

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.caption).lineLimit(2)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
        .foregroundStyle(.red)
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
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.8)
                    if let start = vm.loadingStartTime {
                        Text(start, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 70)
            case .loaded:
                Button("Unload") { Task { await vm.unloadModel() } }
                    .buttonStyle(.bordered).tint(.orange).controlSize(.small)
            case .unloaded:
                Button("Load") { Task { await vm.loadModel() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(vm.models.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - System prompt bar

struct SystemPromptBar: View {
    @Bindable var vm: ChatViewModel
    @Binding var showPresetSave: Bool
    @Binding var newPresetName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("System Prompt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !vm.presets.isEmpty {
                    Menu {
                        ForEach(vm.presets.keys.sorted(), id: \.self) { name in
                            Button(name) { vm.systemPrompt = vm.presets[name] ?? "" }
                        }
                        Divider()
                        ForEach(vm.presets.keys.sorted(), id: \.self) { name in
                            Button(role: .destructive) {
                                vm.presets.removeValue(forKey: name)
                            } label: { Label("Delete \"\(name)\"", systemImage: "trash") }
                        }
                    } label: {
                        Label("Presets", systemImage: "list.bullet").font(.caption)
                    }
                }
                Button {
                    newPresetName = ""
                    showPresetSave = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down").font(.caption)
                }
                .alert("Save Preset", isPresented: $showPresetSave) {
                    TextField("Name", text: $newPresetName)
                    Button("Save") {
                        let name = newPresetName.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { vm.presets[name] = vm.systemPrompt }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            TextEditor(text: $vm.systemPrompt)
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
    let vm: ChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg, isStreaming: vm.isStreaming && msg.id == vm.messages.last?.id) {
                            Task { await vm.regenerateLastResponse() }
                        }
                        .id(msg.id)
                    }
                    if vm.isStreaming, vm.messages.last?.content.isEmpty == true {
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
            .onChange(of: vm.messages.last?.content) {
                withAnimation(.easeOut(duration: 0.1)) {
                    if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.isStreaming) {
                if vm.isStreaming { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onRegenerate: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isUser { Spacer(minLength: 50) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 0) {
                if message.isUser {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    MarkdownView(text: message.content.isEmpty ? " " : message.content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                if !message.isUser && !isStreaming {
                    Button { onRegenerate() } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
            }

            if !message.isUser { Spacer(minLength: 50) }
        }
    }
}

// MARK: - Markdown renderer

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parseSegments(text), id: \.id) { seg in
                SegmentView(segment: seg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SegmentView: View {
    let segment: Segment

    var body: some View {
        switch segment.kind {
        case .code(let lang):
            CodeBlockView(code: segment.text, language: lang)
        case .prose:
            ProseView(text: segment.text)
        }
    }
}

private struct ProseView: View {
    let text: String

    private var lines: [(Int, String)] {
        text.components(separatedBy: "\n")
            .enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.0) { _, line in
                if let attr = try? AttributedString(markdown: line) {
                    Text(attr).textSelection(.enabled)
                } else {
                    Text(line).textSelection(.enabled)
                }
            }
        }
    }
}

private struct Segment: Identifiable {
    let id = UUID()
    let text: String
    enum Kind { case prose, code(String?) }
    let kind: Kind
}

private func parseSegments(_ text: String) -> [Segment] {
    var segments: [Segment] = []
    let pattern = "```(\\w*)\\n([\\s\\S]*?)```"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return [Segment(text: text, kind: .prose)]
    }
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    var lastEnd = 0
    regex.enumerateMatches(in: text, range: full) { match, _, _ in
        guard let m = match else { return }
        if m.range.location > lastEnd {
            let pre = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            let trimmed = pre.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(Segment(text: pre, kind: .prose)) }
        }
        let langR = m.range(at: 1), codeR = m.range(at: 2)
        let lang = langR.location != NSNotFound ? ns.substring(with: langR) : nil
        let code = codeR.location != NSNotFound ? ns.substring(with: codeR) : ""
        segments.append(Segment(text: code, kind: .code(lang?.isEmpty == true ? nil : lang)))
        lastEnd = m.range.upperBound
    }
    if lastEnd < ns.length {
        let tail = ns.substring(from: lastEnd)
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments.append(Segment(text: tail, kind: .prose)) }
    }
    return segments.isEmpty ? [Segment(text: text, kind: .prose)] : segments
}

struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code.trimmingCharacters(in: .newlines)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
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

            if vm.isStreaming {
                Button {
                    vm.stopStreaming()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.red)
                }
            } else {
                Button {
                    focused = false
                    Task { await vm.sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(canSend ? Color.accentColor : Color.gray)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !vm.models.isEmpty
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @Bindable var vm: ChatViewModel
    @Environment(\.dismiss) var dismiss
    @State private var draftURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://host:8081", text: $draftURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: { Text("Server URL") } footer: {
                    Text("Address of your llama-swap instance.")
                }

                Section {
                    Picker("Default Model", selection: $vm.defaultModel) {
                        Text("None").tag("")
                        ForEach(vm.models, id: \.self) { Text($0).tag($0) }
                    }
                } header: { Text("Default Model") } footer: {
                    Text("Auto-selected when no model is running.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.2f", vm.temperature))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $vm.temperature, in: 0...2, step: 0.05)
                    }

                    Stepper("Max Tokens: \(vm.maxTokens == 0 ? "Unlimited" : "\(vm.maxTokens)")",
                            value: $vm.maxTokens, in: 0...32768, step: 256)
                } header: { Text("Generation") } footer: {
                    Text("Max Tokens 0 = server default.")
                }

                Section {
                    Button("Save & Reconnect") {
                        vm.serverURL = draftURL
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
            .onAppear { draftURL = vm.serverURL }
        }
    }
}
