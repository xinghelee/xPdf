import SwiftUI
import PDFKit

struct OCRSheet: View {
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss

    private enum Scope: Hashable { case current, selected, all }

    @State private var scope: Scope = .all
    @State private var language: OCRLanguage = .chineseEnglish
    @State private var skipPagesWithText = true
    @State private var task: Task<Void, Never>?
    @State private var progress = (done: 0, total: 0)
    @State private var result: ViewerModel.OCRResult?
    @State private var copied = false

    private var isRunning: Bool { task != nil && result == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("识别文字（OCR）").font(.headline)
            Text("识别扫描件或图片中的文字，并在页面中加入隐藏的文字层。识别后即可搜索、选择和拷贝文字，页面外观保持不变。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let result {
                resultView(result)
            } else if isRunning {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text(progress.total == 0 ? "正在准备…" : "正在识别第 \(min(progress.done + 1, progress.total)) / \(progress.total) 页…")
                }
            } else {
                Form {
                    Picker("范围", selection: $scope) {
                        Text("当前页").tag(Scope.current)
                        if model.selectedPages.count > 1 {
                            Text("所选的 \(model.selectedPages.count) 页").tag(Scope.selected)
                        }
                        Text("全部 \(model.pages.count) 页").tag(Scope.all)
                    }
                    .pickerStyle(.radioGroup)
                    Picker("语言", selection: $language) {
                        ForEach(OCRLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("跳过已包含文字的页面", isOn: $skipPagesWithText)
                }
            }

            HStack {
                if let result, !result.text.isEmpty {
                    Button(copied ? "已拷贝" : "拷贝识别的文字") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.text, forType: .string)
                        copied = true
                    }
                }
                Spacer()
                if result != nil {
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else if isRunning {
                    Button("停止") { task?.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("开始识别", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(targets.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(isRunning)
        .onAppear {
            if model.selectedPages.count > 1 { scope = .selected }
        }
        .onDisappear { task?.cancel() }
    }

    private var targets: [PDFPage] {
        switch scope {
        case .current: model.currentPage.map { [$0] } ?? []
        case .selected: model.pages.filter { model.selectedPages.contains($0) }
        case .all: model.pages
        }
    }

    private func start() {
        let pages = targets
        progress = (0, 0)
        task = Task { @MainActor in
            let outcome = await model.recognizeText(
                in: pages, language: language, skipPagesWithText: skipPagesWithText
            ) { done, total in
                progress = (done, total)
            }
            result = outcome
        }
    }

    @ViewBuilder
    private func resultView(_ result: ViewerModel.OCRResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                result.cancelled ? "已停止" : (result.recognizedPages > 0 ? "识别完成" : "没有识别到文字"),
                systemImage: result.recognizedPages > 0 ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .foregroundStyle(result.recognizedPages > 0 ? Color.green : Color.orange)
            .font(.body.weight(.medium))
            Text("已识别 \(result.recognizedPages) 页，共 \(result.lineCount) 行文字。"
                 + (result.skippedPages > 0 ? "跳过了 \(result.skippedPages) 页已包含文字的页面。" : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
            if result.recognizedPages > 0 {
                Text("现在可以用 ⌘F 搜索，或直接选择文字拷贝。可通过“编辑 → 撤销”恢复。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ScanBanner: View {
    let model: ViewerModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
            Text("此文档似乎是扫描件，无法搜索或选择文字。")
            Button("识别文字…") { model.isShowingOCR = true }
            Button {
                model.showsScanBanner = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("隐藏提示")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.top, 12)
    }
}
