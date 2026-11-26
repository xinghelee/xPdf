import SwiftUI
import PDFKit

struct SidebarView: View {
    @Bindable var model: ViewerModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("侧边栏", selection: $model.sidebarMode) {
                Image(systemName: "square.grid.2x2").help("缩略图").tag(SidebarMode.thumbnails)
                Image(systemName: "list.bullet.indent").help("目录").tag(SidebarMode.outline)
                Image(systemName: "magnifyingglass").help("搜索结果").tag(SidebarMode.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            switch model.sidebarMode {
            case .thumbnails: ThumbnailSidebar(model: model)
            case .outline: OutlineSidebar(model: model)
            case .search: SearchSidebar(model: model)
            }
        }
    }
}

private struct ThumbnailSidebar: View {
    @Bindable var model: ViewerModel

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selectedPages) {
                ForEach(Array(model.pages.enumerated()), id: \.element) { index, page in
                    PageThumbnail(model: model, page: page, index: index)
                }
                .onMove { model.movePages(from: $0, to: $1) }
            }
            .contextMenu(forSelectionType: PDFPage.self) { selection in
                let targets = model.pages.filter { selection.contains($0) }
                Button("向左旋转") { model.rotate(targets, by: -90) }
                Button("向右旋转") { model.rotate(targets, by: 90) }
                Divider()
                Button("在后面插入文件…") { model.insertFromFiles() }
                Button("在后面插入空白页") { model.insertBlankPage() }
                Divider()
                Button("导出为 PDF…") { model.exportPDF(targets) }
                Button("导出为 PNG 图片…") { model.exportImages(targets) }
                Divider()
                Button("删除页面", role: .destructive) { model.remove(targets) }
            }
            .onDeleteCommand { model.remove(model.targetPages) }
            .onChange(of: model.selectedPages) { _, selection in
                if selection.count == 1, let page = selection.first { model.go(to: page) }
            }
            .onChange(of: model.currentPageIndex) { _, index in
                guard model.pages.indices.contains(index) else { return }
                withAnimation { proxy.scrollTo(model.pages[index]) }
            }
        }
    }
}

private struct PageThumbnail: View {
    let model: ViewerModel
    let page: PDFPage
    let index: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: model.thumbnail(for: page))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 130, maxHeight: 170)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            Text(page.label ?? "\(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

private struct OutlineSidebar: View {
    let model: ViewerModel

    var body: some View {
        if model.outline.isEmpty {
            ContentUnavailableView("没有目录", systemImage: "list.bullet.indent",
                                   description: Text("此文档不包含书签目录"))
        } else {
            List(model.outline, children: \.children) { node in
                Text(node.title)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.go(to: node.destination) }
            }
        }
    }
}

private struct SearchSidebar: View {
    let model: ViewerModel
    @State private var selection: SearchHit.ID?

    var body: some View {
        if model.searchHits.isEmpty {
            if model.searchText.isEmpty {
                ContentUnavailableView("搜索文档", systemImage: "magnifyingglass",
                                       description: Text("在工具栏的搜索框输入关键词并回车"))
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        } else {
            List(selection: $selection) {
                Section("\(model.searchHits.count) 个结果") {
                    ForEach(model.searchHits) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("第 \(hit.pageLabel) 页")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(highlighted(hit.context, query: model.searchText))
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .onChange(of: selection) { _, id in
                if let hit = model.searchHits.first(where: { $0.id == id }) { model.show(hit) }
            }
        }
    }

    private func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        var searchRange = result.startIndex..<result.endIndex
        while let found = result[searchRange].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[found].font = .body.bold()
            result[found].backgroundColor = .yellow.opacity(0.35)
            searchRange = found.upperBound..<result.endIndex
        }
        return result
    }
}
