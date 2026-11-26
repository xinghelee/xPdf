import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct CompressSheet: View {
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss

    @State private var level: CompressionLevel = .balanced
    @State private var originalSize: Int?
    @State private var task: Task<Void, Never>?
    @State private var progress = 0.0
    @State private var result: CompressionResult?
    @State private var errorMessage: String?
    @State private var savedURL: URL?

    private var isRunning: Bool { task != nil && result == nil && errorMessage == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("压缩 PDF").font(.headline)
            Text("降低图片的分辨率并重新编码图片来减小文件。文字、矢量图形、批注、书签和链接保持不变。结果另存为新文件，当前文档不会被修改。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.pdf.isEncrypted {
                Label("加密的文档暂不支持压缩：压缩后的副本无法保留原有的密码保护。", systemImage: "lock")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let result {
                resultView(result)
            } else if isRunning {
                ProgressView(value: progress) { Text("正在压缩…") }
            } else {
                Picker("压缩程度", selection: $level) {
                    ForEach(CompressionLevel.allCases) { level in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(level.title)
                            Text(level.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                if let originalSize {
                    Text("当前大小：\(format(originalSize))").font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                if model.pdf.isEncrypted || errorMessage != nil {
                    Button("好") { dismiss() }.keyboardShortcut(.defaultAction)
                } else if let result {
                    if result.isSmaller {
                        Button(savedURL == nil ? "取消" : "完成") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("存储为…") { save(result.data) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                } else if isRunning {
                    Button("停止") { task?.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("压缩", action: start).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(isRunning)
        .onAppear {
            if !model.pdf.isEncrypted { originalSize = model.currentDocumentData()?.count }
        }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard let data = model.currentDocumentData() else {
            errorMessage = "无法读取文档。"
            return
        }
        originalSize = data.count
        progress = 0
        let level = level
        task = Task { @MainActor in
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try PDFCompressor.compress(data, level: level) { value in
                        DispatchQueue.main.async { progress = value }
                    }
                }.value
                if !Task.isCancelled { result = outcome }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stem = model.fileURL?.deletingPathExtension().lastPathComponent ?? "文档"
        panel.nameFieldStringValue = "\(stem)（压缩）.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            savedURL = url
            dismiss()
        } catch {
            errorMessage = "存储失败：\(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func resultView(_ result: CompressionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.isSmaller {
                let saved = 100 - Int((Double(result.data.count) / Double(result.originalSize) * 100).rounded())
                Label("\(format(result.originalSize)) → \(format(result.data.count))，减小 \(saved)%",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body.weight(.medium))
            } else {
                Label("这个文档无法进一步压缩", systemImage: "info.circle")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.medium))
                Text("文档中没有可以安全缩小的图片。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if result.protectedPages > 0 {
                Text("有 \(result.protectedPages) 页压缩后文字无法正确保留（无法搜索或拷贝），这些页保持原样。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.linkedPages > 0 {
                Text("有 \(result.linkedPages) 页被书签或链接指向，为保证跳转正常，这些页保持原样。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
