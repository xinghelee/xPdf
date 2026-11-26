import SwiftUI
import PDFKit

extension FocusedValues {
    @Entry var viewer: ViewerModel?
}

struct ViewerCommands: Commands {
    @FocusedValue(\.viewer) private var model

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("打印…") { model?.print() }
                .keyboardShortcut("p")
                .disabled(model == nil)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("放大") { model?.zoomIn() }.keyboardShortcut("=")
            Button("缩小") { model?.zoomOut() }.keyboardShortcut("-")
            Button("实际大小") { model?.actualSize() }.keyboardShortcut("0")
            Button("适合窗口") { model?.zoomToFit() }.keyboardShortcut("9")
            Divider()
            Menu("页面显示") {
                Button("单页") { model?.displayMode = .singlePage }
                Button("单页连续") { model?.displayMode = .singlePageContinuous }
                Button("双页") { model?.displayMode = .twoUp }
                Button("双页连续") { model?.displayMode = .twoUpContinuous }
            }
            Divider()
        }

        CommandMenu("页面") {
            Group {
                Button("上一页") { model?.previousPage() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("下一页") { model?.nextPage() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("向左旋转") { model.map { $0.rotate($0.targetPages, by: -90) } }
                    .keyboardShortcut("l")
                Button("向右旋转") { model.map { $0.rotate($0.targetPages, by: 90) } }
                    .keyboardShortcut("r")
                Divider()
                Button("插入文件中的页面…") { model?.insertFromFiles() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("插入空白页") { model?.insertBlankPage() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("将所选页面导出为 PDF…") { model.map { $0.exportPDF($0.targetPages) } }
                Button("将所选页面导出为 PNG…") { model.map { $0.exportImages($0.targetPages) } }
                Divider()
                Button("删除所选页面") { model.map { $0.remove($0.targetPages) } }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .disabled(model == nil)
        }

        CommandMenu("批注") {
            Group {
                ForEach(Array(MarkupTool.allCases.enumerated()), id: \.element) { index, tool in
                    Button("\(tool.title)工具") { model?.tool = tool }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                }
                Divider()
                Button("添加文字批注…") { model?.isEditingNote = true }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("新建签名…") { model?.isCreatingSignature = true }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("清除表单内容") { model?.resetForm() }
                    .disabled(model?.hasForm != true)
            }
            .disabled(model == nil)
        }
    }
}
