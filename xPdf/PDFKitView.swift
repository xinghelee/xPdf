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
        super.mouseDown(with: event)
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
        if var state = drag {
            let p = convert(point, to: state.page)
            let dx = p.x - state.start.x
            let dy = p.y - state.start.y
            if state.resizing {
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
            inkPoints = []
            inkPage = nil
            updateInkOverlay()
            return
        }
        if model.tool == .eraser { return }
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
        if model.pendingSignature != nil || model.tool == .ink {
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

    private func isOnResizeHandle(_ p: CGPoint, of annotation: PDFAnnotation) -> Bool {
        guard annotation.type == "Ink" else { return false }
        let handle = 10 / max(scaleFactor, 0.01)
        return abs(p.x - annotation.bounds.maxX) < handle && abs(p.y - annotation.bounds.minY) < handle
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

    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !points.isEmpty else { return }
        let path = StrokePath.bezier(points)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
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
