import SwiftUI
import PDFKit

struct PDFKitView: NSViewRepresentable {
    let model: ViewerModel

    func makeNSView(context: Context) -> XPDFView {
        let view = XPDFView()
        view.document = model.pdf
        view.autoScales = true
        view.displayMode = model.displayMode
        view.displaysPageBreaks = true
        view.model = model
        model.attach(view)
        return view
    }

    func updateNSView(_ view: XPDFView, context: Context) {}
}

final class XPDFView: PDFView {
    weak var model: ViewerModel?

    private static let movableTypes: Set<String> = ["Ink", "FreeText", "Stamp", "Square", "Circle", "Line", "Text"]
    private static let ignoredTypes: Set<String> = ["Link", "Widget", "Popup"]

    // Freehand stroke in progress (view coordinates).
    private var inkPoints: [CGPoint] = []
    private var inkPage: PDFPage?
    private lazy var inkOverlay: InkOverlayView = {
        let overlay = InkOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        return overlay
    }()

    // Shape being dragged out (view coordinates).
    private var shapeStart: CGPoint?
    private var shapePage: PDFPage?

    // Annotation being moved or resized.
    private struct DragState {
        let page: PDFPage
        let annotation: PDFAnnotation
        let start: CGPoint
        let bounds: CGRect
        let paths: [NSBezierPath]?
        let resizing: Bool
        var moved = false
    }
    private var drag: DragState?
    private var choiceMenu: NSMenu?

    /// Undo manager for PDFKit's form text editing view while it is active. Keeps its
    /// per-keystroke undo out of the document's stack: inside a field ⌘Z undoes typing,
    /// and the finished entry is a single "填写表单" step in the document.
    private let fieldEditingUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        if let editor = window?.firstResponder as? NSView, editor !== self, editor.isDescendant(of: self) {
            return fieldEditingUndoManager
        }
        return super.undoManager
    }

    func resetFieldEditingUndo() {
        fieldEditingUndoManager.removeAllActions()
    }

    // MARK: - Sharp annotations

    // PDFView draws page content in tiles rendered for the current zoom, but draws annotations in
    // separate layers whose contentsScale stays at 1, so ink, notes and stamps turn blurry and
    // pixelated when zoomed in. Raise those layers' scale to match the zoom and redraw them.
    private var sharpenTimer: Timer?
    private var sharpenObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sharpenTimer?.invalidate()
        sharpenTimer = nil
        sharpenObservers.forEach(NotificationCenter.default.removeObserver)
        sharpenObservers = []
        guard window != nil else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDisplayModeChanged] {
            sharpenObservers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                self?.sharpenAnnotationsSoon()
            })
        }
        if let clip = enclosingScrollViewForSharpening?.contentView {
            clip.postsBoundsChangedNotifications = true
            sharpenObservers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.sharpenAnnotations()
            })
        }
        // Catches annotation layers created any other way (new ink, undo, scrolling into view).
        sharpenTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sharpenAnnotations()
        }
    }

    private var enclosingScrollViewForSharpening: NSScrollView? {
        subviews.lazy.compactMap { $0 as? NSScrollView }.first
    }

    func sharpenAnnotationsSoon() {
        DispatchQueue.main.async { [weak self] in self?.sharpenAnnotations() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.sharpenAnnotations() }
    }

    private func sharpenAnnotations() {
        guard let window, window.isVisible, let root = layer else { return }
        let target = scaleFactor * window.backingScaleFactor
        sharpen(root, target: target, depth: 0)
    }

    private func sharpen(_ layer: CALayer, target: CGFloat, depth: Int) {
        guard depth < 12 else { return }
        if NSStringFromClass(type(of: layer)).hasPrefix("PDFPageLayerAnnotation") {
            // Keep each layer's backing store within 4096 px on its longer side.
            let side = max(layer.bounds.width, layer.bounds.height, 1)
            let scale = max(1, min(target, 4096 / side))
            if abs(layer.contentsScale - scale) > 0.01 {
                layer.contentsScale = scale
                layer.setNeedsDisplay()
            }
            return
        }
        for sublayer in layer.sublayers ?? [] { sharpen(sublayer, target: target, depth: depth + 1) }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let model else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)

        if let signature = model.pendingSignature {
            if let page = page(for: point, nearest: true) {
                model.placeSignature(signature, at: convert(point, to: page), on: page)
            }
            return
        }

        switch model.tool {
        case .ink:
            inkPage = page(for: point, nearest: true)
            inkPoints = [point]
            updateInkOverlay()
            return
        case .eraser:
            erase(at: point)
            return
        case .shape:
            shapePage = page(for: point, nearest: true)
            shapeStart = point
            return
        case .select:
            if let (page, annotation) = annotationHit(at: point, movableOnly: true) {
                let p = convert(point, to: page)
                drag = DragState(
                    page: page,
                    annotation: annotation,
                    start: p,
                    bounds: annotation.bounds,
                    paths: annotation.paths?.compactMap { $0.copy() as? NSBezierPath },
                    resizing: isOnResizeHandle(p, of: annotation)
                )
                return
            }
        default:
            break
        }
        if let (page, field) = popUpChoiceField(at: point) {
            showChoiceMenu(for: field, on: page)
            return
        }
        super.mouseDown(with: event)
        model.checkFormChanges()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)

        if model.tool == .ink, !inkPoints.isEmpty {
            inkPoints.append(point)
            updateInkOverlay()
            return
        }
        if model.tool == .eraser {
            erase(at: point)
            return
        }
        if model.tool == .shape, let start = shapeStart {
            inkOverlay.color = model.inkColor.nsColor
            inkOverlay.lineWidth = model.inkWidth * scaleFactor
            inkOverlay.shape = (model.shapeKind, start, constrained(point, from: start, kind: model.shapeKind, event: event))
            return
        }
        if var state = drag {
            let p = convert(point, to: state.page)
            let dx = p.x - state.start.x
            let dy = p.y - state.start.y
            if state.resizing, ["Square", "Circle"].contains(state.annotation.type ?? "") {
                // Rectangles and ellipses: drag the bottom-right corner freely; the top-left stays fixed.
                let width = max(6, state.bounds.width + dx)
                let height = max(6, state.bounds.height - dy)
                let newBounds = CGRect(x: state.bounds.minX, y: state.bounds.maxY - height, width: width, height: height)
                ViewerModel.applyGeometry(state.annotation, bounds: newBounds, paths: nil)
            } else if state.resizing {
                // Drag the bottom-right corner; keep the top-left fixed and the aspect ratio.
                let width = max(16, state.bounds.width + dx)
                let scale = width / state.bounds.width
                let height = state.bounds.height * scale
                let newBounds = CGRect(x: state.bounds.minX, y: state.bounds.maxY - height, width: width, height: height)
                let scaled = state.paths?.map { original -> NSBezierPath in
                    let path = original.copy() as! NSBezierPath
                    path.transform(using: AffineTransform(scale: scale))
                    path.lineWidth = original.lineWidth
                    return path
                }
                ViewerModel.applyGeometry(state.annotation, bounds: newBounds, paths: scaled)
            } else {
                ViewerModel.applyGeometry(state.annotation, bounds: state.bounds.offsetBy(dx: dx, dy: dy), paths: nil)
            }
            state.moved = true
            drag = state
            annotationsChanged(on: state.page)
            sharpenAnnotationsSoon()
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return super.mouseUp(with: event) }

        if model.tool == .ink, !inkPoints.isEmpty {
            if let page = inkPage {
                model.addInk(points: inkPoints.map { convert($0, to: page) }, on: page)
            }
            sharpenAnnotationsSoon()
            inkPoints = []
            inkPage = nil
            updateInkOverlay()
            return
        }
        if model.tool == .eraser { return }
        if model.tool == .shape, let start = shapeStart {
            let end = constrained(convert(event.locationInWindow, from: nil), from: start, kind: model.shapeKind, event: event)
            if let page = shapePage {
                model.addShape(model.shapeKind, from: convert(start, to: page), to: convert(end, to: page), on: page)
                sharpenAnnotationsSoon()
            }
            shapeStart = nil
            shapePage = nil
            inkOverlay.shape = nil
            return
        }
        if let state = drag {
            drag = nil
            if state.moved {
                model.didChangeGeometry(
                    state.annotation, on: state.page,
                    oldBounds: state.bounds,
                    oldPaths: state.resizing ? state.paths : nil,
                    name: state.resizing ? "调整大小" : "移动批注"
                )
            }
            return
        }

        super.mouseUp(with: event)
        model.checkFormChanges()
        guard let subtype = model.tool.subtype,
              let selection = currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        model.applyMarkup(subtype, to: selection)
        clearSelection()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.pendingSignature != nil || model.tool == .ink || model.tool == .shape {
            NSCursor.crosshair.set()
        } else if model.tool == .eraser {
            (annotationHit(at: point, movableOnly: false) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        } else if model.tool == .select, let (page, annotation) = annotationHit(at: point, movableOnly: true) {
            if isOnResizeHandle(convert(point, to: page), of: annotation) {
                NSCursor.frameResize(position: .bottomRight, directions: .all).set()
            } else {
                NSCursor.openHand.set()
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if model?.pendingSignature != nil {
            model?.pendingSignature = nil
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: - Helpers

    private func annotationHit(at point: CGPoint, movableOnly: Bool) -> (PDFPage, PDFAnnotation)? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let p = convert(point, to: page)
        let slop = 4 / max(scaleFactor, 0.01)
        for annotation in page.annotations.reversed()
        where annotation.bounds.insetBy(dx: -slop, dy: -slop).contains(p) {
            let type = annotation.type ?? ""
            if Self.ignoredTypes.contains(type) { continue }
            if movableOnly && !Self.movableTypes.contains(type) { continue }
            return (page, annotation)
        }
        return nil
    }

    /// A non-editable combo box field. PDFKit's own pop-up for these ignores the zoom level
    /// and renders tiny items, so a standard menu is shown instead.
    private func popUpChoiceField(at point: CGPoint) -> (PDFPage, PDFAnnotation)? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let p = convert(point, to: page)
        guard let field = page.annotations.last(where: {
            $0.type == "Widget" && $0.widgetFieldType == .choice && $0.bounds.contains(p)
        }), !field.isListChoice, !(field.choices ?? []).isEmpty else { return nil }
        let flags = (field.value(forAnnotationKey: .widgetFieldFlags) as? NSNumber)?.intValue ?? 0
        let editable = flags & (1 << 18) != 0
        return editable ? nil : (page, field)
    }

    private func showChoiceMenu(for field: PDFAnnotation, on page: PDFPage) {
        let menu = NSMenu()
        // Menu items only weakly reference their target; keep the menu alive until its action has run.
        choiceMenu = menu
        defer { DispatchQueue.main.async { [weak self] in self?.choiceMenu = nil } }
        menu.font = .menuFont(ofSize: 0)
        var selected: NSMenuItem?
        for choice in field.choices ?? [] {
            let item = ClosureMenuItem(title: choice) { [weak self] in
                guard field.widgetStringValue != choice else { return }
                // Apply after menu tracking ends so the change lands in a normal undo group.
                DispatchQueue.main.async {
                    field.widgetStringValue = choice
                    self?.annotationsChanged(on: page)
                    self?.model?.checkFormChanges()
                }
            }
            if choice == field.widgetStringValue {
                item.state = .on
                selected = item
            }
            menu.addItem(item)
        }
        let rect = convert(field.bounds, from: page)
        menu.minimumWidth = rect.width
        let origin = NSPoint(x: rect.minX, y: isFlipped ? rect.minY : rect.maxY)
        menu.popUp(positioning: selected, at: origin, in: self)
    }

    private func isOnResizeHandle(_ p: CGPoint, of annotation: PDFAnnotation) -> Bool {
        guard ["Ink", "Stamp", "Square", "Circle"].contains(annotation.type ?? "") else { return false }
        let handle = 10 / max(scaleFactor, 0.01)
        return abs(p.x - annotation.bounds.maxX) < handle && abs(p.y - annotation.bounds.minY) < handle
    }

    /// With Shift held: squares and circles for boxes, 45° steps for lines.
    private func constrained(_ point: CGPoint, from start: CGPoint, kind: ShapeKind, event: NSEvent) -> CGPoint {
        guard event.modifierFlags.contains(.shift) else { return point }
        let dx = point.x - start.x, dy = point.y - start.y
        switch kind {
        case .rectangle, .ellipse, .whiteout:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        case .line, .arrow:
            let length = hypot(dx, dy)
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
    }

    // MARK: - Paste

    /// ⌘V with an image on the clipboard inserts it on the current page.
    @objc func paste(_ sender: Any?) {
        if model?.pasteImage() != true { NSSound.beep() }
    }

    private func erase(at point: CGPoint) {
        guard let (page, annotation) = annotationHit(at: point, movableOnly: false) else { return }
        model?.removeAnnotations([(page, annotation)], name: "擦除")
    }

    private func updateInkOverlay() {
        guard let model else { return }
        inkOverlay.color = model.inkColor.nsColor
        inkOverlay.lineWidth = model.inkWidth * scaleFactor
        inkOverlay.points = inkPoints
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let model else { return menu }
        var items: [NSMenuItem] = []

        let point = convert(event.locationInWindow, from: nil)
        if let (page, annotation) = annotationHit(at: point, movableOnly: false) {
            items.append(ClosureMenuItem(title: "删除批注") {
                model.removeAnnotations([(page, annotation)])
            })
        }

        if let selection = currentSelection, !(selection.string ?? "").isEmpty {
            for tool in MarkupTool.allCases {
                guard let subtype = tool.subtype else { continue }
                items.append(ClosureMenuItem(title: tool.title) { [weak self] in
                    model.applyMarkup(subtype, to: selection)
                    self?.clearSelection()
                })
            }
        }

        if !items.isEmpty {
            items.append(.separator())
            for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        }
        return menu
    }
}

/// Live preview of the stroke being drawn; transparent to mouse events.
final class InkOverlayView: NSView {
    var points: [CGPoint] = [] { didSet { needsDisplay = true } }
    var color: NSColor = .black
    var lineWidth: CGFloat = 2
    /// Shape preview: kind, start and current point.
    var shape: (ShapeKind, CGPoint, CGPoint)? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let (kind, start, end) = shape {
            drawShape(kind, from: start, to: end)
            return
        }
        guard !points.isEmpty else { return }
        let path = StrokePath.bezier(points)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

extension InkOverlayView {
    fileprivate func drawShape(_ kind: ShapeKind, from start: CGPoint, to end: CGPoint) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        let path: NSBezierPath
        switch kind {
        case .rectangle: path = NSBezierPath(rect: rect)
        case .ellipse: path = NSBezierPath(ovalIn: rect)
        case .whiteout:
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.secondaryLabelColor.setStroke()
            outline.stroke()
            return
        case .line, .arrow:
            path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            if kind == .arrow, hypot(end.x - start.x, end.y - start.y) > 1 {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let size = max(8, lineWidth * 4)
                let head = NSBezierPath()
                head.move(to: end)
                head.line(to: CGPoint(x: end.x - size * cos(angle - .pi / 7), y: end.y - size * sin(angle - .pi / 7)))
                head.line(to: CGPoint(x: end.x - size * cos(angle + .pi / 7), y: end.y - size * sin(angle + .pi / 7)))
                head.close()
                color.setFill()
                head.fill()
            }
        }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
