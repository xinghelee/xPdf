import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// When each document was last opened in xPdf. The list of recent documents itself comes from
/// NSDocumentController, which also keeps the sandbox access to them.
enum OpenHistory {
    private static let key = "history.lastOpened"
    private static let limit = 200

    static func record(_ url: URL) {
        var dates = all()
        dates[url.standardizedFileURL.path] = Date()
        if dates.count > limit {
            for (path, _) in dates.sorted(by: { $0.value < $1.value }).prefix(dates.count - limit) {
                dates[path] = nil
            }
        }
        UserDefaults.standard.set(dates.mapValues { $0.timeIntervalSince1970 }, forKey: key)
    }

    static func lastOpened(_ url: URL) -> Date? { all()[url.standardizedFileURL.path] }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    private static func all() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }
}

struct RecentDocument: Identifiable, Hashable {
    let url: URL
    let lastOpened: Date?
    var id: URL { url }

    var name: String { url.deletingPathExtension().lastPathComponent }

    var folder: String {
        let path = url.deletingLastPathComponent().path
        // In the sandbox the home directory APIs return the app's container, so ask the user database.
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return path }
        let home = String(cString: dir)
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct WelcomeView: View {
    static let windowID = "welcome"

    @Environment(\.openDocument) private var openDocument
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("welcome.showAtLaunch") private var showAtLaunch = true

    @State private var recents: [RecentDocument] = []
    @State private var selection: RecentDocument.ID?
    @State private var query = ""
    @State private var errorMessage: String?

    private var filtered: [RecentDocument] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recents }
        return recents.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            actions
                .frame(width: 300)
            Divider()
            recentList
                .frame(width: 420)
        }
        .frame(height: 460)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }
            pdfs.forEach(open)
            return !pdfs.isEmpty
        }
        .alert("无法打开文档", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Left

    private var actions: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("xPdf")
                .font(.system(size: 30, weight: .semibold))
                .padding(.top, 6)
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(spacing: 8) {
                WelcomeAction(title: "打开 PDF…", systemImage: "folder") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o")
                WelcomeAction(title: "新建空白文档", systemImage: "doc.badge.plus") {
                    newDocument { PDFFile() }
                    dismissWindow(id: Self.windowID)
                }
                .keyboardShortcut("n")
            }
            .padding(.top, 28)
            .padding(.horizontal, 36)

            Spacer()
            Toggle("启动时显示此窗口", isOn: $showAtLaunch)
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Right

    private var recentList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("最近使用").font(.headline)
                Spacer()
                if !recents.isEmpty {
                    Menu {
                        Button("清除最近使用的文档", role: .destructive) {
                            NSDocumentController.shared.clearRecentDocuments(nil)
                            OpenHistory.clear()
                            reload()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if recents.count > 6 {
                TextField("搜索", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if recents.isEmpty {
                ContentUnavailableView {
                    Label("没有最近使用的文档", systemImage: "clock")
                } description: {
                    Text("打开的 PDF 会显示在这里。也可以把 PDF 拖到这个窗口。")
                }
                .frame(maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                List(filtered, selection: $selection) { document in
                    RecentRow(document: document)
                        .tag(document.id)
                        .contextMenu {
                            Button("打开") { open(document.url) }
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([document.url])
                            }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: RecentDocument.ID.self, menu: { _ in }) { ids in
                    ids.forEach(open)
                }
                .onKeyPress(.return) {
                    guard let selection else { return .ignored }
                    open(selection)
                    return .handled
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
    }

    private func reload() {
        let urls = NSDocumentController.shared.recentDocumentURLs
        recents = urls
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { RecentDocument(url: $0, lastOpened: OpenHistory.lastOpened($0)) }
        if let selection, !recents.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: Self.windowID)
            } catch {
                errorMessage = error.localizedDescription
                reload()
            }
        }
    }
}

private struct WelcomeAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

private struct RecentRow: View {
    let document: RecentDocument
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: document.url.path))
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 34, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(document.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if let date = document.lastOpened {
                Text(Self.format(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .help(document.url.path)
        .task(id: document.url) { thumbnail = await Self.thumbnail(for: document.url) }
    }

    private static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month().day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 34, height: 44),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return representation.nsImage
    }
}
