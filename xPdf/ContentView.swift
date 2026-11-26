import SwiftUI
import PDFKit

struct ContentView: View {
    let document: PDFFile
    @State private var model: ViewerModel
    @Environment(\.undoManager) private var undoManager

    init(document: PDFFile) {
        self.document = document
        _model = State(initialValue: ViewerModel(pdf: document.pdf, originalData: document.originalData))
    }

    var body: some View {
        Group {
            if model.isLocked {
                UnlockView(model: model)
            } else {
                NavigationSplitView {
                    SidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 360)
                } detail: {
                    ZStack {
                        PDFKitView(model: model)
                        if model.pages.isEmpty { EmptyDocumentView(model: model) }
                    }
                    .overlay(alignment: .top) {
                        if model.pendingSignature != nil {
                            PlacementBanner(model: model)
                        } else if model.hasForm && model.showsFormBanner {
                            FormBanner(model: model)
                        } else if model.looksScanned && model.showsScanBanner {
                            ScanBanner(model: model)
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        model.insertFiles(urls, at: model.insertionIndex)
                        return true
                    }
                    .toolbar { DocumentToolbar(model: model) }
                }
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "在文档中搜索")
                .onSubmit(of: .search) { model.performSearch() }
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .focusedSceneValue(\.viewer, model)
        .onAppear {
            model.undoManager = undoManager
            document.commitPendingEdits = { [model] in model.commitFormEditing() }
        }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .sheet(isPresented: $model.isEditingNote) { NoteSheet(model: model) }
        .sheet(isPresented: $model.isCreatingSignature) { SignatureSheet(model: model) }
        .sheet(isPresented: $model.isShowingOCR) { OCRSheet(model: model) }
        .alert("出错了", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct DocumentToolbar: ToolbarContent {
    @Bindable var model: ViewerModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { model.previousPage() } label: { Label("上一页", systemImage: "chevron.up") }
                Button { model.nextPage() } label: { Label("下一页", systemImage: "chevron.down") }
            }
            PageNumberField(model: model)
        }

        ToolbarItem {
            Picker("工具", selection: $model.tool) {
                ForEach(MarkupTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .help("选中文字后自动添加所选批注")
        }

        ToolbarItem {
            Menu {
                Picker("标记颜色", selection: $model.markupColor) {
                    ForEach(MarkupColor.allCases) { ColorLabel(color: $0).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("画笔 / 签名颜色", selection: $model.inkColor) {
                    ForEach(MarkupColor.allCases) { ColorLabel(color: $0).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("画笔粗细", selection: $model.inkWidth) {
                    Text("细").tag(CGFloat(1))
                    Text("中").tag(CGFloat(2))
                    Text("粗").tag(CGFloat(4))
                    Text("特粗").tag(CGFloat(8))
                }
                .pickerStyle(.inline)
            } label: {
                Label("颜色", systemImage: "paintpalette")
            }
            .help("批注颜色与画笔粗细")
        }

        ToolbarItem {
            SignatureMenu(model: model)
        }

        ToolbarItem {
            Button { model.isEditingNote = true } label: {
                Label("添加文字", systemImage: "character.textbox")
            }
            .help("在当前位置添加文字批注")
            .disabled(model.pages.isEmpty)
        }

        ToolbarItem {
            ControlGroup {
                Button { model.zoomOut() } label: { Label("缩小", systemImage: "minus.magnifyingglass") }
                Menu("\(Int((model.scale * 100).rounded()))%") {
                    Button("适合窗口") { model.zoomToFit() }
                    Button("实际大小") { model.actualSize() }
                    Divider()
                    ForEach([50, 75, 100, 125, 150, 200, 300], id: \.self) { percent in
                        Button("\(percent)%") { model.pdfView?.scaleFactor = CGFloat(percent) / 100 }
                    }
                }
                Button { model.zoomIn() } label: { Label("放大", systemImage: "plus.magnifyingglass") }
            }
        }

        ToolbarItem {
            Menu {
                Picker("显示方式", selection: $model.displayMode) {
                    Text("单页").tag(PDFDisplayMode.singlePage)
                    Text("单页连续").tag(PDFDisplayMode.singlePageContinuous)
                    Text("双页").tag(PDFDisplayMode.twoUp)
                    Text("双页连续").tag(PDFDisplayMode.twoUpContinuous)
                }
                .pickerStyle(.inline)
            } label: {
                Label("显示方式", systemImage: "rectangle.split.2x1")
            }
        }

        ToolbarItem {
            Button { model.rotate(model.targetPages, by: 90) } label: {
                Label("旋转", systemImage: "rotate.right")
            }
            .help("向右旋转所选页面")
            .disabled(model.pages.isEmpty)
        }
    }
}

struct PageNumberField: View {
    let model: ViewerModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("页码", text: $text)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .onSubmit {
                    if let number = Int(text) { model.goToPage(number - 1) }
                    text = "\(model.currentPageIndex + 1)"
                }
            Text("/ \(model.pages.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .onAppear { text = "\(model.currentPageIndex + 1)" }
        .onChange(of: model.currentPageIndex) { _, index in text = "\(index + 1)" }
    }
}

struct EmptyDocumentView: View {
    let model: ViewerModel

    var body: some View {
        ContentUnavailableView {
            Label("空白文档", systemImage: "doc")
        } description: {
            Text("从文件插入页面，或把 PDF / 图片拖到这里")
        } actions: {
            Button("插入文件…") { model.insertFromFiles() }
            Button("插入空白页") { model.insertBlankPage() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct UnlockView: View {
    let model: ViewerModel
    @State private var password = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.doc")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("此 PDF 已加密").font(.title2)
            SecureField("密码", text: $password)
                .frame(width: 240)
                .onSubmit(unlock)
            if failed {
                Text("密码不正确").foregroundStyle(.red).font(.callout)
            }
            Button("解锁", action: unlock)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlock() {
        failed = !model.unlock(password: password)
    }
}

struct NoteSheet: View {
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加文字批注").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 380, height: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") {
                    model.addTextNote(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

struct ColorLabel: View {
    let color: MarkupColor

    var body: some View {
        Label {
            Text(color.title)
        } icon: {
            Image(nsImage: color.swatch)
        }
    }
}

struct SignatureMenu: View {
    let model: ViewerModel
    private var store: SignatureStore { .shared }

    var body: some View {
        Menu {
            ForEach(Array(store.signatures.enumerated()), id: \.element.id) { index, signature in
                Button {
                    model.beginPlacing(signature)
                } label: {
                    Label {
                        Text("签名 \(index + 1)")
                    } icon: {
                        Image(nsImage: signature.previewImage())
                    }
                }
            }
            if !store.signatures.isEmpty { Divider() }
            Button("新建签名…") { model.isCreatingSignature = true }
            if !store.signatures.isEmpty {
                Menu("删除签名") {
                    ForEach(Array(store.signatures.enumerated()), id: \.element.id) { index, signature in
                        Button {
                            store.remove(signature)
                        } label: {
                            Label {
                                Text("签名 \(index + 1)")
                            } icon: {
                                Image(nsImage: signature.previewImage())
                            }
                        }
                    }
                }
            }
        } label: {
            Label("签名", systemImage: "signature")
        }
        .help("添加签名")
        .disabled(model.pages.isEmpty)
    }
}

struct PlacementBanner: View {
    let model: ViewerModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "signature")
            Text("点击页面放置签名。放置后可拖动移动，拖右下角缩放。")
            Button("取消") { model.pendingSignature = nil }
                .keyboardShortcut(.cancelAction)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.top, 12)
    }
}

struct FormBanner: View {
    let model: ViewerModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
            Text("此文档包含可填写的表单，点击字段即可填写，Tab 键切换下一个字段。")
            Button("清除表单") { model.resetForm() }
            Button {
                model.showsFormBanner = false
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
