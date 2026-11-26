import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum SidebarMode: String, CaseIterable, Identifiable {
    case thumbnails, outline, search
    var id: Self { self }
}

enum MarkupTool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strikeOut, ink, eraser
    var id: Self { self }

    var title: String {
        switch self {
        case .select: "选择"
        case .highlight: "高亮"
        case .underline: "下划线"
        case .strikeOut: "删除线"
        case .ink: "画笔"
        case .eraser: "橡皮擦"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .ink: "pencil.tip"
        case .eraser: "eraser"
        }
    }

    var subtype: PDFAnnotationSubtype? {
        switch self {
        case .select, .ink, .eraser: nil
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        }
    }
}

enum MarkupColor: String, CaseIterable, Identifiable {
    case black, yellow, green, blue, pink, red
    var id: Self { self }

    var title: String {
        switch self {
        case .black: "黑色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .pink: "粉色"
        case .red: "红色"
        }
    }

    /// Colored dot for menus. Not a template image, so menus keep the real color.
    var swatch: NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            dot.fill()
            NSColor.gray.withAlphaComponent(0.5).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    var nsColor: NSColor {
        switch self {
        case .black: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.1, alpha: 1)
        case .yellow: NSColor(srgbRed: 1.0, green: 0.85, blue: 0.1, alpha: 1)
        case .green: NSColor(srgbRed: 0.3, green: 0.85, blue: 0.4, alpha: 1)
        case .blue: NSColor(srgbRed: 0.3, green: 0.6, blue: 1.0, alpha: 1)
        case .pink: NSColor(srgbRed: 1.0, green: 0.45, blue: 0.7, alpha: 1)
        case .red: NSColor(srgbRed: 0.95, green: 0.25, blue: 0.2, alpha: 1)
        }
    }
}

struct SearchHit: Identifiable {
    let id = UUID()
    let selection: PDFSelection
    let pageLabel: String
    let context: String
}

struct OutlineNode: Identifiable {
    let id = UUID()
    let title: String
    let destination: PDFDestination?
    let children: [OutlineNode]?

    static func build(_ outline: PDFOutline?) -> [OutlineNode] {
        guard let outline else { return [] }
        return (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }.map { child in
            OutlineNode(
                title: child.label ?? "",
                destination: child.destination ?? (child.action as? PDFActionGoTo)?.destination,
                children: child.numberOfChildren > 0 ? build(child) : nil
            )
        }
    }
}

@Observable
final class ViewerModel {
    let pdf: PDFDocument

    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let thumbnailCache = NSCache<NSString, NSImage>()
    // Pages copied from other files keep a reference to their source document.
    @ObservationIgnored private var sourceDocuments: [PDFDocument] = []
    // PDFView runs its own OCR on displayed scan pages and writes the result straight into the page
    // content, so a page's real content can only be read from a copy that is never displayed.
    // Maps each page in `pdf` to such a copy: the same page of a second, hidden PDFDocument opened
    // from the original file, or the source page a copy was inserted from.
    @ObservationIgnored private let pristineDocument: PDFDocument?
    @ObservationIgnored private var pristinePages: [ObjectIdentifier: PDFPage] = [:]
    // Last known value of every form field, used to detect edits PDFKit makes without telling the undo manager.
    @ObservationIgnored private var formSnapshot: [ObjectIdentifier: FieldValue] = [:]
    // Text field whose current typing session already has an undo entry.
    @ObservationIgnored private var editingField: PDFAnnotation?

    var isLocked: Bool
    var pages: [PDFPage] = []
    var outline: [OutlineNode] = []
    var currentPageIndex = 0
    var selectedPages: Set<PDFPage> = []
    var scale: CGFloat = 1
    var sidebarMode: SidebarMode = .thumbnails
    var displayMode: PDFDisplayMode = .singlePageContinuous {
        didSet { pdfView?.displayMode = displayMode }
    }
    var tool: MarkupTool = .select {
        didSet { if tool != .select { pendingSignature = nil } }
    }
    var markupColor: MarkupColor = .yellow
    var inkColor: MarkupColor = .black
    var inkWidth: CGFloat = 2
    var pendingSignature: Signature?
    var isCreatingSignature = false
    var hasForm = false
    var showsFormBanner = true
    var isShowingOCR = false
    var isShowingCompress = false
    /// Where the document lives, if it has been saved.
    var fileURL: URL?
    /// No page among the first few has a text layer: probably a scan.
    var looksScanned = false
    var showsScanBanner = true
    var searchText = "" {
        didSet { if searchText.isEmpty { clearSearch() } }
    }
    var searchHits: [SearchHit] = []
    var isEditingNote = false
    var errorMessage: String?
    private(set) var thumbnailRevision = 0

    init(pdf: PDFDocument, originalData: Data? = nil) {
        self.pdf = pdf
        pristineDocument = originalData.flatMap { PDFDocument(data: $0) }
        isLocked = pdf.isLocked
        thumbnailCache.countLimit = 400
        if !isLocked { reloadContent() }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - View wiring

    func attach(_ view: PDFView) {
        pdfView = view
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                self?.syncCurrentPage()
            },
            center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
                self?.scale = view?.scaleFactor ?? 1
            },
        ]
        // PDFKit edits text fields through a field editor inside the PDFView.
        for name in [NSText.didChangeNotification, NSControl.textDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak view] note in
                guard let view, let editor = note.object as? NSView, editor.isDescendant(of: view) else { return }
                self?.formTextDidChange(in: editor)
            })
        }
        for name in [NSText.didEndEditingNotification, NSControl.textDidEndEditingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak view] note in
                guard let view, (note.object as? NSView)?.isDescendant(of: view) == true else { return }
                self?.formTextDidEndEditing()
            })
        }
        // Choice fields change through a pop-up menu.
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.checkFormChanges() }
        })
        scale = view.scaleFactor
        syncCurrentPage()
    }

    private func reloadContent() {
        pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
        if let pristine = pristineDocument, pristine.pageCount == pages.count {
            for (index, page) in pages.enumerated() {
                if let original = pristine.page(at: index) { pristinePages[ObjectIdentifier(page)] = original }
            }
        }
        outline = OutlineNode.build(pdf.outlineRoot)
        refreshFormBaseline()
        looksScanned = !pages.isEmpty && !pages.prefix(5).contains(where: hasText)
    }

    /// The never-displayed counterpart of `page`, or the page itself if there is none.
    func pristine(_ page: PDFPage) -> PDFPage {
        pristinePages[ObjectIdentifier(page)] ?? page
    }

    func hasText(_ page: PDFPage) -> Bool {
        OCREngine.hasTextContent(pristine(page))
    }

    private func syncCurrentPage() {
        guard let page = pdfView?.currentPage else { return }
        let index = pdf.index(for: page)
        if index != NSNotFound, index != currentPageIndex { currentPageIndex = index }
        if !selectedPages.contains(page) { selectedPages = [page] }
    }

    private func pagesDidChange(relayout: Bool = false) {
        pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
        thumbnailRevision += 1
        if relayout { pdfView?.layoutDocumentView() }
        syncCurrentPage()
        refreshFormBaseline()
    }

    private func registerUndo(_ name: String, _ handler: @escaping (ViewerModel) -> Void) {
        guard let undoManager else { return }
        // Automatic event grouping only runs in the default run loop mode; changes made while a
        // menu is tracking would otherwise have no open group, so open one explicitly.
        let needsGroup = undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(name)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    func thumbnail(for page: PDFPage) -> NSImage {
        let key = "\(ObjectIdentifier(page).hashValue)-\(thumbnailRevision)" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let image = page.thumbnail(of: CGSize(width: 260, height: 340), for: .cropBox)
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Unlock

    func unlock(password: String) -> Bool {
        guard pdf.unlock(withPassword: password) else { return false }
        _ = pristineDocument?.unlock(withPassword: password)
        isLocked = false
        reloadContent()
        return true
    }

    // MARK: - Navigation & zoom

    var currentPage: PDFPage? { pdfView?.currentPage }

    func go(to page: PDFPage) {
        guard pdfView?.currentPage != page else { return }
        pdfView?.go(to: page)
    }

    func go(to destination: PDFDestination?) {
        guard let destination else { return }
        pdfView?.go(to: destination)
    }

    func goToPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        pdfView?.go(to: pages[index])
    }

    func previousPage() { pdfView?.goToPreviousPage(nil) }
    func nextPage() { pdfView?.goToNextPage(nil) }
    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }
    func actualSize() { pdfView?.scaleFactor = 1 }
    func zoomToFit() { pdfView?.autoScales = true }

    func print() {
        pdfView?.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    // MARK: - Page operations

    /// Selected pages in document order, or the current page when nothing is selected.
    var targetPages: [PDFPage] {
        let selected = pages.filter { selectedPages.contains($0) }
        if !selected.isEmpty { return selected }
        return currentPage.map { [$0] } ?? []
    }

    var insertionIndex: Int {
        guard let last = targetPages.last, let index = pages.firstIndex(of: last) else { return pages.count }
        return index + 1
    }

    func rotate(_ targets: [PDFPage], by degrees: Int) {
        guard !targets.isEmpty else { return }
        for page in targets {
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        registerUndo("旋转页面") { $0.rotate(targets, by: -degrees) }
        pagesDidChange(relayout: true)
    }

    func remove(_ targets: [PDFPage], name: String = "删除页面") {
        let items = targets
            .map { (pdf.index(for: $0), $0) }
            .filter { $0.0 != NSNotFound }
            .sorted { $0.0 < $1.0 }
        guard !items.isEmpty else { return }
        for (index, _) in items.reversed() { pdf.removePage(at: index) }
        selectedPages.subtract(targets)
        registerUndo(name) { $0.insert(items, name: name) }
        pagesDidChange()
    }

    /// Inserts pages at the given indices (must be ascending).
    func insert(_ items: [(Int, PDFPage)], name: String = "插入页面") {
        guard !items.isEmpty else { return }
        for (index, page) in items { pdf.insert(page, at: min(index, pdf.pageCount)) }
        registerUndo(name) { $0.remove(items.map(\.1), name: name) }
        pagesDidChange()
        selectedPages = Set(items.map(\.1))
        if let first = items.first?.1 { pdfView?.go(to: first) }
    }

    func movePages(from source: IndexSet, to destination: Int) {
        var order = pages
        order.move(fromOffsets: source, toOffset: destination)
        apply(order: order, name: "移动页面")
    }

    private func apply(order: [PDFPage], name: String) {
        let previous = pages
        for (target, page) in order.enumerated() {
            let current = pdf.index(for: page)
            guard current != NSNotFound, current != target else { continue }
            pdf.removePage(at: current)
            pdf.insert(page, at: target)
        }
        registerUndo(name) { $0.apply(order: previous, name: name) }
        pagesDidChange()
    }

    func insertFromFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "选择要插入的 PDF 或图片"
        panel.prompt = "插入"
        guard panel.runModal() == .OK else { return }
        insertFiles(panel.urls, at: insertionIndex)
    }

    func insertFiles(_ urls: [URL], at index: Int) {
        var newPages: [PDFPage] = []
        var skipped: [String] = []
        for url in urls {
            if let doc = PDFDocument(url: url) {
                if doc.isLocked { skipped.append(url.lastPathComponent); continue }
                sourceDocuments.append(doc)
                for i in 0..<doc.pageCount {
                    guard let source = doc.page(at: i), let page = source.copy() as? PDFPage else { continue }
                    pristinePages[ObjectIdentifier(page)] = source
                    newPages.append(page)
                }
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                newPages.append(page)
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        if !skipped.isEmpty {
            errorMessage = "以下文件无法插入（不受支持或已加密）：\n" + skipped.joined(separator: "\n")
        }
        insert(newPages.enumerated().map { (index + $0.offset, $0.element) })
    }

    func insertBlankPage() {
        let page = PDFPage()
        let size = currentPage?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        insert([(insertionIndex, page)], name: "插入空白页")
    }

    func exportPDF(_ targets: [PDFPage]) {
        guard !targets.isEmpty else { return }
        let output = PDFDocument()
        for page in targets {
            if let copy = page.copy() as? PDFPage { output.insert(copy, at: output.pageCount) }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "导出的页面.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !output.write(to: url) { errorMessage = "导出失败。" }
    }

    func exportImages(_ targets: [PDFPage]) {
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "选择导出 PNG 图片的文件夹"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        for page in targets {
            let bounds = page.bounds(for: .cropBox)
            let side = max(bounds.width, bounds.height) * 2
            let image = page.thumbnail(of: CGSize(width: side, height: side), for: .cropBox)
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let number = pdf.index(for: page) + 1
            do {
                try png.write(to: folder.appendingPathComponent("第\(number)页.png"))
            } catch {
                errorMessage = "导出失败：\(error.localizedDescription)"
                return
            }
        }
    }

    // MARK: - Annotations

    func applyMarkup(_ subtype: PDFAnnotationSubtype, to selection: PDFSelection) {
        var added: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.color = subtype == .highlight
                    ? markupColor.nsColor.withAlphaComponent(0.45)
                    : markupColor.nsColor
                annotation.userName = NSFullUserName()
                added.append((page, annotation))
            }
        }
        let name = MarkupTool.allCases.first { $0.subtype == subtype }?.title ?? "批注"
        addAnnotations(added, name: name)
    }

    func addTextNote(_ text: String) {
        guard let view = pdfView else { return }
        let centerInView = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let page = view.page(for: centerInView, nearest: true) else { return }
        let font = NSFont.systemFont(ofSize: 14)
        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: 260, height: 10_000),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        ).size
        let width = ceil(textSize.width) + 16
        let height = ceil(textSize.height) + 12
        let pageBounds = page.bounds(for: .cropBox)
        var center = view.convert(centerInView, to: page)
        center.x = min(max(center.x, pageBounds.minX + width / 2), pageBounds.maxX - width / 2)
        center.y = min(max(center.y, pageBounds.minY + height / 2), pageBounds.maxY - height / 2)

        let annotation = PDFAnnotation(
            bounds: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = .black
        annotation.color = markupColor.nsColor.withAlphaComponent(0.3)
        annotation.userName = NSFullUserName()
        addAnnotations([(page, annotation)], name: "添加文字")
    }

    func addAnnotations(_ items: [(PDFPage, PDFAnnotation)], name: String) {
        guard !items.isEmpty else { return }
        for (page, annotation) in items { page.addAnnotation(annotation) }
        registerUndo(name) { $0.removeAnnotations(items, name: name) }
        thumbnailRevision += 1
    }

    // MARK: - Ink & signatures

    /// Adds a freehand stroke. `points` are in page space.
    func addInk(points: [CGPoint], on page: PDFPage) {
        guard !points.isEmpty else { return }
        let path = StrokePath.bezier(points)
        let pad = inkWidth * 2
        let bounds = path.bounds.insetBy(dx: -pad, dy: -pad)
        path.transform(using: AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY))
        path.lineWidth = inkWidth
        let annotation = makeInk(bounds: bounds, paths: [path], width: inkWidth)
        addAnnotations([(page, annotation)], name: "手绘")
    }

    func beginPlacing(_ signature: Signature) {
        tool = .select
        pendingSignature = signature
    }

    /// Places a signature centered on `point` (page space).
    func placeSignature(_ signature: Signature, at point: CGPoint, on page: PDFPage) {
        let b = signature.bounds
        var scale = 170 / max(b.width, 1)
        if b.height * scale > 80 { scale = 80 / max(b.height, 1) }
        let lineWidth: CGFloat = 1.6
        let pad = lineWidth * 2
        let size = CGSize(width: b.width * scale + pad * 2, height: b.height * scale + pad * 2)
        let pageBounds = page.bounds(for: .cropBox)
        let origin = CGPoint(
            x: min(max(point.x - size.width / 2, pageBounds.minX), pageBounds.maxX - size.width),
            y: min(max(point.y - size.height / 2, pageBounds.minY), pageBounds.maxY - size.height)
        )
        // Canvas is y-down, PDF is y-up: flip while scaling into annotation-local space.
        let paths = signature.strokes.map { stroke -> NSBezierPath in
            let path = StrokePath.bezier(stroke.map {
                CGPoint(x: ($0.x - b.minX) * scale + pad, y: (b.maxY - $0.y) * scale + pad)
            })
            path.lineWidth = lineWidth
            return path
        }
        let annotation = makeInk(bounds: CGRect(origin: origin, size: size), paths: paths, width: lineWidth)
        annotation.contents = "签名"
        addAnnotations([(page, annotation)], name: "添加签名")
        pendingSignature = nil
    }

    private func makeInk(bounds: CGRect, paths: [NSBezierPath], width: CGFloat) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        for path in paths { annotation.add(path) }
        annotation.color = inkColor.nsColor
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        annotation.userName = NSFullUserName()
        return annotation
    }

    /// Sets bounds (and optionally replaces ink paths, which are relative to the bounds origin).
    static func applyGeometry(_ annotation: PDFAnnotation, bounds: CGRect, paths: [NSBezierPath]?) {
        annotation.bounds = bounds
        if let paths {
            for path in annotation.paths ?? [] { annotation.remove(path) }
            for path in paths { annotation.add(path) }
        }
    }

    /// Records an already-applied move/resize so it can be undone.
    func didChangeGeometry(_ annotation: PDFAnnotation, on page: PDFPage,
                           oldBounds: CGRect, oldPaths: [NSBezierPath]?, name: String) {
        registerUndo(name) { $0.setGeometry(annotation, on: page, bounds: oldBounds, paths: oldPaths, name: name) }
        thumbnailRevision += 1
    }

    func setGeometry(_ annotation: PDFAnnotation, on page: PDFPage,
                     bounds: CGRect, paths: [NSBezierPath]?, name: String) {
        let oldBounds = annotation.bounds
        let oldPaths = paths == nil ? nil : annotation.paths?.compactMap { $0.copy() as? NSBezierPath }
        Self.applyGeometry(annotation, bounds: bounds, paths: paths)
        pdfView?.annotationsChanged(on: page)
        didChangeGeometry(annotation, on: page, oldBounds: oldBounds, oldPaths: oldPaths, name: name)
    }

    func removeAnnotations(_ items: [(PDFPage, PDFAnnotation)], name: String = "删除批注") {
        guard !items.isEmpty else { return }
        for (page, annotation) in items { page.removeAnnotation(annotation) }
        registerUndo(name) { $0.addAnnotations(items, name: name) }
        thumbnailRevision += 1
    }

    // MARK: - Forms

    struct FieldValue: Equatable {
        var text: String?
        var state: Int
    }

    private var formFields: [PDFAnnotation] {
        pages.flatMap { page in page.annotations.filter { $0.type == "Widget" } }
    }

    private func fieldValue(_ field: PDFAnnotation) -> FieldValue {
        field.widgetFieldType == .button
            ? FieldValue(text: nil, state: field.buttonWidgetState.rawValue)
            : FieldValue(text: field.widgetStringValue, state: 0)
    }

    private func setFieldValue(_ field: PDFAnnotation, _ value: FieldValue) {
        if field.widgetFieldType == .button {
            field.buttonWidgetState = PDFWidgetCellState(rawValue: value.state) ?? .offState
        } else {
            field.widgetStringValue = value.text ?? ""
        }
    }

    private func refreshFormBaseline() {
        var snapshot: [ObjectIdentifier: FieldValue] = [:]
        for field in formFields { snapshot[ObjectIdentifier(field)] = fieldValue(field) }
        formSnapshot = snapshot
        hasForm = !snapshot.isEmpty
    }

    /// Compares every field with the snapshot and records changed ones as one undo step.
    func checkFormChanges(name: String = "填写表单") {
        guard hasForm else { return }
        var previous: [(PDFAnnotation, FieldValue)] = []
        for field in formFields {
            let id = ObjectIdentifier(field)
            let value = fieldValue(field)
            guard let old = formSnapshot[id] else { formSnapshot[id] = value; continue }
            guard old != value else { continue }
            formSnapshot[id] = value
            if field !== editingField { previous.append((field, old)) }
        }
        guard !previous.isEmpty else { return }
        registerUndo(name) { $0.restoreFields(previous, name: name) }
        thumbnailRevision += 1
    }

    private func restoreFields(_ items: [(PDFAnnotation, FieldValue)], name: String) {
        commitFormEditing()
        let current = items.map { ($0.0, fieldValue($0.0)) }
        for (field, value) in items {
            setFieldValue(field, value)
            formSnapshot[ObjectIdentifier(field)] = value
        }
        for page in Set(items.compactMap { $0.0.page }) { pdfView?.annotationsChanged(on: page) }
        registerUndo(name) { $0.restoreFields(current, name: name) }
        thumbnailRevision += 1
    }

    /// First keystroke of a typing session: register undo right away so the document becomes dirty.
    private func formTextDidChange(in editor: NSView) {
        guard editingField == nil,
              let field = formField(under: editor),
              let old = formSnapshot[ObjectIdentifier(field)] else { return }
        editingField = field
        registerUndo("填写表单") { $0.restoreFields([(field, old)], name: "填写表单") }
    }

    /// The text widget that PDFKit's editing view is placed over.
    private func formField(under editor: NSView) -> PDFAnnotation? {
        guard let view = pdfView else { return nil }
        let center = editor.convert(NSPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: view)
        guard let page = view.page(for: center, nearest: false) else { return nil }
        let point = view.convert(center, to: page)
        return page.annotations.last {
            $0.type == "Widget" && $0.widgetFieldType != .button && $0.bounds.contains(point)
        }
    }

    private func formTextDidEndEditing() {
        (pdfView as? XPDFView)?.resetFieldEditingUndo()
        // PDFKit writes the field value after the notification, so check on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.checkFormChanges()
            self?.editingField = nil
        }
    }

    /// Ends any in-progress text entry so its value is written into the field.
    func commitFormEditing() {
        guard let view = pdfView, let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder !== view, responder.isDescendant(of: view) else { return }
        window.makeFirstResponder(view)
    }

    func resetForm() {
        commitFormEditing()
        for field in formFields {
            if field.widgetFieldType == .button {
                if field.widgetControlType != .pushButtonControl { field.buttonWidgetState = .offState }
            } else {
                field.widgetStringValue = ""
            }
        }
        for page in pages { pdfView?.annotationsChanged(on: page) }
        checkFormChanges(name: "清除表单")
    }

    // MARK: - Compression

    /// The document as it would be saved now, including unsaved edits.
    func currentDocumentData() -> Data? {
        commitFormEditing()
        return pdf.dataRepresentation()
    }

    // MARK: - OCR

    struct OCRResult {
        var recognizedPages = 0
        /// Already had text; rebuilding them could damage that text, so they are always skipped.
        var pagesWithText = 0
        /// Bookmarks or links point to them; skipped unless the user opted in.
        var linkedPagesSkipped = 0
        var lineCount = 0
        var text = ""
        var cancelled = false
    }

    /// Recognizes text on `targets` and replaces them with copies that carry an invisible text layer.
    /// The whole run is one undo step. Cancelling keeps the pages finished so far.
    @MainActor
    func recognizeText(in targets: [PDFPage], language: OCRLanguage, includeLinkedPages: Bool,
                       progress: @escaping (Int, Int) -> Void) async -> OCRResult {
        // Pages with text are never rebuilt: redrawing a page re-embeds its fonts, and for many
        // fonts the text then no longer extracts correctly.
        let withoutText = targets.filter { !hasText($0) }
        let referenced = PageReferences.referencedPages(in: pdf)
        let todo = includeLinkedPages ? withoutText : withoutText.filter { !referenced.contains(ObjectIdentifier($0)) }
        var result = OCRResult(pagesWithText: targets.count - withoutText.count,
                               linkedPagesSkipped: withoutText.count - todo.count)
        var replacements: [(PDFPage, PDFPage)] = []
        var texts: [String] = []

        for (index, page) in todo.enumerated() {
            progress(index, todo.count)
            if Task.isCancelled { result.cancelled = true; break }
            let content = pristine(page)
            guard let image = OCREngine.renderImage(of: content, rotation: page.rotation) else { continue }
            let codes = language.codes
            let lines = (try? await Task.detached(priority: .userInitiated) {
                try OCREngine.recognize(image, languages: codes)
            }.value) ?? []
            if Task.isCancelled { result.cancelled = true; break }
            guard !lines.isEmpty,
                  let (document, newPage) = OCREngine.makeSearchablePage(from: content, rotation: page.rotation, lines: lines)
            else { continue }
            sourceDocuments.append(document)
            // Re-running OCR on this page should start from the original content again, not stack layers.
            pristinePages[ObjectIdentifier(newPage)] = content
            replacements.append((page, newPage))
            result.lineCount += lines.count
            texts.append(lines.map(\.text).joined(separator: "\n"))
        }
        progress(todo.count, todo.count)

        replacePages(replacements, name: "文字识别")
        result.recognizedPages = replacements.count
        result.text = texts.joined(separator: "\n\n")
        if !replacements.isEmpty { looksScanned = false }
        return result
    }

    /// Pages among `targets` that have no text yet but are bookmark or link targets.
    func linkedPagesWithoutText(in targets: [PDFPage]) -> Int {
        let referenced = PageReferences.referencedPages(in: pdf)
        return targets.filter { referenced.contains(ObjectIdentifier($0)) && !hasText($0) }.count
    }

    /// Swaps pages in place, moving annotations (including form fields) onto the replacement.
    /// Bookmarks and links that point to a replaced page break when saved (see PageReferences).
    func replacePages(_ pairs: [(PDFPage, PDFPage)], name: String) {
        guard !pairs.isEmpty else { return }
        let index = currentPageIndex
        for (old, new) in pairs {
            let position = pdf.index(for: old)
            guard position != NSNotFound else { continue }
            for annotation in old.annotations {
                old.removeAnnotation(annotation)
                new.addAnnotation(annotation)
            }
            pdf.removePage(at: position)
            pdf.insert(new, at: position)
        }
        let mapping = Dictionary(uniqueKeysWithValues: pairs.map { (ObjectIdentifier($0.0), $0.1) })
        selectedPages = Set(selectedPages.map { mapping[ObjectIdentifier($0)] ?? $0 })
        // Old selections point at the replaced pages.
        searchText = ""
        clearSearch()
        registerUndo(name) { $0.replacePages(pairs.map { ($0.1, $0.0) }, name: name) }
        pagesDidChange()
        goToPage(index)
    }

    // MARK: - Search

    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearch(); return }
        let results = pdf.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        searchHits = results.map { selection in
            let page = selection.pages.first
            let index = page.map { pdf.index(for: $0) } ?? 0
            let context = (selection.copy() as? PDFSelection) ?? selection
            context.extendForLineBoundaries()
            let text = (context.string ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SearchHit(selection: selection, pageLabel: "\(index + 1)", context: text)
        }
        for selection in results { selection.color = .systemYellow }
        pdfView?.highlightedSelections = results
        sidebarMode = .search
        if let first = searchHits.first { show(first) }
    }

    func show(_ hit: SearchHit) {
        pdfView?.setCurrentSelection(hit.selection, animate: true)
        pdfView?.go(to: hit.selection)
    }

    func clearSearch() {
        searchHits = []
        pdfView?.highlightedSelections = nil
    }
}
