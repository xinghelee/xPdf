import SwiftUI
import PDFKit

/// One conversation about one document. Kept in memory only.
@Observable
final class ChatSession {
    struct Quote: Equatable {
        let text: String
        /// Zero-based page index.
        let page: Int?
    }

    struct Message: Identifiable {
        let id = UUID()
        let role: AIMessage.Role
        var text: String
        var quote: Quote? = nil
        var error: String? = nil

        /// What is sent to the model for this message.
        var content: String {
            guard let quote else { return text }
            let page = quote.page.map { "（第 \($0 + 1) 页）" } ?? ""
            return "我在文档中选中了下面这段文字\(page)：\n\"\"\"\n\(quote.text)\n\"\"\"\n\n\(text)"
        }
    }

    var messages: [Message] = []
    var draft = ""
    private(set) var isResponding = false
    @ObservationIgnored private var task: Task<Void, Never>?

    @MainActor
    func send(_ question: String, quote: Quote?, viewer: ViewerModel) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        messages.append(Message(role: .user, text: question, quote: quote))
        respond(viewer: viewer)
    }

    /// Asks again for the last question, dropping the failed reply.
    @MainActor
    func retry(viewer: ViewerModel) {
        guard !isResponding, let last = messages.lastIndex(where: { $0.role == .user }) else { return }
        messages.removeSubrange((last + 1)...)
        respond(viewer: viewer)
    }

    func stop() { task?.cancel() }

    func clear() {
        stop()
        messages = []
    }

    @MainActor
    private func respond(viewer: ViewerModel) {
        let settings = AISettings.shared
        let provider = settings.provider
        let key = settings.key(for: provider), model = settings.model(for: provider)
        guard !key.isEmpty, !model.isEmpty else { return }

        // Failed replies are left out; an unanswered question before them would break the
        // user/assistant alternation, so only complete pairs plus the new question are sent.
        var history: [AIMessage] = []
        for message in messages where message.error == nil && !message.text.isEmpty {
            if message.role == .user, history.last?.role == .user { history.removeLast() }
            history.append(AIMessage(role: message.role, content: message.content))
        }
        let context = viewer.aiContext(budget: provider.documentBudget)
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        isResponding = true

        task = Task { @MainActor [weak self] in
            var failure: String?
            do {
                let stream = AIClient.stream(provider: provider, key: key, model: model,
                                             system: context.system, document: context.document, messages: history)
                for try await chunk in stream {
                    self?.update(reply.id) { $0.text += chunk }
                }
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            let cancelled = Task.isCancelled
            update(reply.id) { message in
                if let failure {
                    message.error = failure
                } else if message.text.isEmpty, !cancelled {
                    message.error = "没有收到回复。"
                }
            }
            if cancelled, let index = messages.firstIndex(where: { $0.id == reply.id }), messages[index].text.isEmpty {
                messages.remove(at: index)
            }
            isResponding = false
            task = nil
        }
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }
}

extension ViewerModel {
    /// The system prompt and the document text (with page markers) sent with each question.
    func aiContext(budget: Int) -> (system: String, document: String) {
        let name = fileURL?.lastPathComponent ?? "未命名文档"
        var body = "", included = 0, empty = 0
        var truncated = false
        for (index, page) in pages.enumerated() {
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { empty += 1; continue }
            let block = "【第 \(index + 1) 页】\n\(text)\n\n"
            if body.count + block.count > budget {
                truncated = true
                break
            }
            body += block
            included = index + 1
        }

        var system = """
        你是 PDF 阅读器 xPdf 里的文档助手，帮助用户阅读和理解当前打开的文档。
        - 根据提供的文档内容回答。文档里没有的信息要明确说明，不要编造。
        - 引用文档内容时用「第 N 页」标注出处，N 是文档内容中【第 N 页】标记里的数字。
        - 用用户提问的语言回答，简洁清楚，可以使用 Markdown 的粗体和列表。

        当前文档：《\(name)》，共 \(pages.count) 页。
        """
        if body.isEmpty {
            system += "这份文档没有可读取的文字（可能是扫描件或图片）。请告诉用户可以先用 xPdf 的「识别文字（OCR）」功能处理，再来提问。"
        } else {
            if truncated { system += "文档太长，下面只包含前 \(included) 页的文字。" }
            if empty > 0 { system += "有 \(empty) 页没有可读取的文字（可能是图片）。" }
        }
        let document = body.isEmpty ? "" : "<document>\n\(body)</document>"
        return (system, document)
    }
}

// MARK: - Panel

struct AIChatPanel: View {
    let model: ViewerModel
    @Bindable private var settings = AISettings.shared
    @State private var dismissedQuote: ChatSession.Quote?
    @FocusState private var inputFocused: Bool

    private var chat: ChatSession { model.chat }

    private var quote: ChatSession.Quote? {
        guard let text = model.selectedText else { return nil }
        let quote = ChatSession.Quote(text: String(text.prefix(4000)), page: model.selectedTextPage)
        return quote == dismissedQuote ? nil : quote
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if settings.isReady(settings.provider) {
                conversation
                Divider()
                input
            } else {
                setup
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Picker("服务", selection: $settings.provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(settings.isReady(provider)
                         ? "\(provider.title) · \(settings.model(for: provider))"
                         : "\(provider.title)（未设置）")
                        .tag(provider)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("选择 AI 服务")
            Spacer()
            Button { chat.clear() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("新对话")
                .disabled(chat.messages.isEmpty)
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("AI 设置")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var setup: some View {
        ContentUnavailableView {
            Label("设置 \(settings.provider.title)", systemImage: "key")
        } description: {
            Text("在设置中填写 \(settings.provider.title) 的 API Key 后即可开始对话。")
        } actions: {
            SettingsLink { Text("打开设置…") }
        }
        .frame(maxHeight: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if chat.messages.isEmpty {
                    suggestions
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { message in
                            MessageView(message: message, isLast: message.id == chat.messages.last?.id,
                                        isResponding: chat.isResponding) {
                                chat.retry(viewer: model)
                            }
                            .id(message.id)
                        }
                    }
                    .padding(12)
                }
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.count) {
                if let last = chat.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "xpdf-page", let number = Int(url.host() ?? "") else { return .discarded }
            model.goToPage(number - 1)
            return .handled
        })
    }

    private var suggestions: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("关于这份文档，想了解什么？")
                .font(.headline)
            VStack(spacing: 8) {
                ForEach(["总结这份文档", "列出文档的要点", "文档里有哪些关键数据？"], id: \.self) { prompt in
                    Button(prompt) { send(prompt) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            Text("提问时，文档的文字会发送给 \(settings.provider.title)。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quote {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote")
                    Text(quote.text.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button { dismissedQuote = quote } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("不引用选中的文字")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .help("提问时会附上在文档中选中的文字")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(quote == nil ? "问问这份文档…" : "关于选中的文字…", text: Bindable(chat).draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .onSubmit { send(chat.draft) }
                if chat.isResponding {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help("停止")
                } else {
                    Button { send(chat.draft) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("发送（Return）")
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .padding(10)
        .onAppear { inputFocused = true }
    }

    private func send(_ text: String) {
        guard !chat.isResponding, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let quote = quote
        chat.send(text, quote: quote, viewer: model)
        chat.draft = ""
        dismissedQuote = quote
    }
}

private struct MessageView: View {
    let message: ChatSession.Message
    let isLast: Bool
    let isResponding: Bool
    let retry: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if let quote = message.quote {
                    Text(quote.text)
                        .lineLimit(3)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 30)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(Self.render(message.text))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .contextMenu {
                            Button("拷贝回答") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.text, forType: .string)
                            }
                        }
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLast { Button("重试", action: retry).controlSize(.small) }
                } else if message.text.isEmpty, isLast, isResponding {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Light Markdown: headings become bold lines, list markers become bullets, and page
    /// references become links that jump to the page.
    static func render(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                return "**\(line[range.upperBound...].trimmingCharacters(in: .whitespaces))**"
            }
            return line.replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
        }
        let linked = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"第\s*(\d{1,5})\s*页"#, with: "[第 $1 页](xpdf-page://$1)", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var result = try? AttributedString(markdown: linked, options: options) else { return AttributedString(text) }
        // The reply is untrusted (a document can carry instructions for the model): keep only the
        // page links added above, so a reply cannot plant a clickable link to an outside URL.
        for run in result.runs where run.link.map({ $0.scheme != "xpdf-page" }) == true {
            result[run.range].link = nil
        }
        return result
    }
}

// MARK: - Settings

struct AISettingsView: View {
    var body: some View {
        Form {
            ForEach(AIProvider.allCases) { provider in
                Section(provider.title) { ProviderSettings(provider: provider) }
            }
            Section {
                Text("API Key 保存在系统钥匙串中。提问时，当前文档的文字和你的问题会发送给所选的服务商，费用按各服务商的价格计算。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProviderSettings: View {
    let provider: AIProvider
    @State private var settings = AISettings.shared
    @State private var keyText = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        SecureField("API Key", text: $keyText, prompt: Text("粘贴 API Key"))
            .onAppear {
                keyText = settings.key(for: provider)
                if !keyText.isEmpty, settings.availableModels[provider] == nil {
                    Task { await settings.refreshModels(for: provider) }
                }
            }
            .onChange(of: keyText) { _, value in
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    settings.setKey(value, for: provider)
                }
            }
        LabeledContent("模型") {
            HStack(spacing: 8) {
                if settings.loading.contains(provider) {
                    ProgressView().controlSize(.small)
                }
                if let models = settings.availableModels[provider], !models.isEmpty {
                    Picker("模型", selection: Binding(
                        get: { settings.model(for: provider) },
                        set: { settings.setModel($0, for: provider) }
                    )) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else if !settings.model(for: provider).isEmpty {
                    Text(settings.model(for: provider)).foregroundStyle(.secondary)
                } else {
                    Text(settings.key(for: provider).isEmpty ? "填写 API Key 后自动获取" : "—")
                        .foregroundStyle(.secondary)
                }
                if !settings.key(for: provider).isEmpty {
                    Button { Task { await settings.refreshModels(for: provider) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重新获取模型列表")
                    .disabled(settings.loading.contains(provider))
                }
            }
        }
        if let error = settings.errors[provider] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        Link("获取 \(provider.title) API Key", destination: provider.keyPage)
            .font(.callout)
    }
}
