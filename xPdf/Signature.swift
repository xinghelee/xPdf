import SwiftUI
import AppKit

/// A handwritten signature stored as vector strokes in canvas coordinates (y grows downward).
struct Signature: Codable, Identifiable, Hashable {
    var id = UUID()
    var strokes: [[CGPoint]]

    var bounds: CGRect {
        let points = strokes.flatMap { $0 }
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Small template image for menus.
    func previewImage(maxWidth: CGFloat = 140, maxHeight: CGFloat = 32) -> NSImage {
        let b = bounds
        let scale = min(maxWidth / max(b.width, 1), maxHeight / max(b.height, 1))
        let size = NSSize(width: max(b.width * scale, 1) + 4, height: max(b.height * scale, 1) + 4)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            for stroke in strokes {
                let path = StrokePath.bezier(stroke.map {
                    CGPoint(x: ($0.x - b.minX) * scale + 2, y: ($0.y - b.minY) * scale + 2)
                })
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum StrokePath {
    /// Chaikin corner-cutting to smooth raw pointer samples into a polyline.
    /// Kept as straight segments because PDF ink annotations store plain point lists.
    static func smoothed(_ points: [CGPoint], iterations: Int = 2) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result = points
        for _ in 0..<iterations {
            var next = [result[0]]
            for i in 0..<(result.count - 1) {
                let a = result[i], b = result[i + 1]
                next.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                next.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            next.append(result[result.count - 1])
            result = next
        }
        return result
    }

    static func bezier(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        let pts = smoothed(points)
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.line(to: CGPoint(x: first.x + 0.5, y: first.y))
        } else {
            for p in pts.dropFirst() { path.line(to: p) }
        }
        return path
    }

    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        let pts = smoothed(points)
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y))
        } else {
            for p in pts.dropFirst() { path.addLine(to: p) }
        }
        return path
    }
}

@Observable
final class SignatureStore {
    static let shared = SignatureStore()

    private(set) var signatures: [Signature] = []
    @ObservationIgnored private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xPdf", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("signatures.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Signature].self, from: data) {
            signatures = saved
        }
    }

    func add(_ signature: Signature) {
        signatures.append(signature)
        save()
    }

    func remove(_ signature: Signature) {
        signatures.removeAll { $0.id == signature.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(signatures) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct SignatureSheet: View {
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []

    private let canvasSize = CGSize(width: 520, height: 200)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建签名").font(.headline)
            Text("用鼠标或触控板在下方书写，保存后可重复使用。")
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                Path { p in
                    p.move(to: CGPoint(x: 30, y: canvasSize.height - 50))
                    p.addLine(to: CGPoint(x: canvasSize.width - 30, y: canvasSize.height - 50))
                }
                .stroke(Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                if strokes.isEmpty && current.isEmpty {
                    Text("在此签名")
                        .font(.title)
                        .foregroundStyle(Color.gray.opacity(0.45))
                }
                Canvas { context, _ in
                    for stroke in strokes + [current] where !stroke.isEmpty {
                        context.stroke(
                            StrokePath.path(stroke),
                            with: .color(.black),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = value.location
                        guard p.x >= 0, p.y >= 0, p.x <= canvasSize.width, p.y <= canvasSize.height else { return }
                        current.append(p)
                    }
                    .onEnded { _ in
                        if !current.isEmpty { strokes.append(current) }
                        current = []
                    }
            )

            HStack {
                Button("撤销一笔") { _ = strokes.popLast() }
                    .disabled(strokes.isEmpty)
                Button("清除") { strokes = [] }
                    .disabled(strokes.isEmpty)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存并放置") {
                    let signature = Signature(strokes: strokes)
                    SignatureStore.shared.add(signature)
                    model.beginPlacing(signature)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(strokes.isEmpty)
            }
        }
        .padding(20)
    }
}
