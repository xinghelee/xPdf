import PDFKit
import Quartz

enum CompressionLevel: String, CaseIterable, Identifiable {
    case high, balanced, smallest
    var id: Self { self }

    var title: String {
        switch self {
        case .high: "高质量"
        case .balanced: "平衡"
        case .smallest: "最小"
        }
    }

    var detail: String {
        switch self {
        case .high: "图片 200 dpi，适合打印"
        case .balanced: "图片 150 dpi，适合屏幕阅读"
        case .smallest: "图片 100 dpi，适合发送，图片质量明显降低"
        }
    }

    fileprivate var settings: (quality: Double, dpi: Int, maxSize: Int) {
        switch self {
        case .high: (0.85, 200, 4000)
        case .balanced: (0.7, 150, 3000)
        case .smallest: (0.5, 100, 2000)
        }
    }
}

struct CompressionResult {
    let data: Data
    let originalSize: Int
    let compressedPages: Int
    /// Pages left as they were because compressing them changed their text or annotations.
    let protectedPages: Int
    /// Pages left as they were because bookmarks or links point to them.
    let linkedPages: Int
    var isSmaller: Bool { data.count < originalSize }
}

enum CompressionError: LocalizedError {
    case unreadable, filterFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取文档。"
        case .filterFailed: "压缩失败。"
        }
    }
}

/// Shrinks a PDF by recompressing and downsampling its images with a Quartz filter.
///
/// The filter redraws every page, which also re-embeds fonts, and for some fonts the text no longer
/// maps back to the right characters (CJK hanzi become Kangxi radicals; some embedded fonts lose
/// their text entirely). It can also upsample low-resolution images. So each filtered page is only
/// used if its text and annotations are unchanged and it actually got smaller; otherwise the
/// original page is kept. Pages that bookmarks or links point to are never replaced (see PageReferences).
enum PDFCompressor {
    /// Runs off the main thread: works on its own copies of the document, never the displayed one.
    static func compress(_ source: Data, level: CompressionLevel,
                         progress: @escaping (Double) -> Void) throws -> CompressionResult {
        guard let original = PDFDocument(data: source) else { throw CompressionError.unreadable }
        let filterURL = try makeFilter(for: level)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xpdf-compress-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: filterURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        guard let filter = QuartzFilter(url: filterURL),
              original.write(to: outputURL, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]),
              let filteredData = try? Data(contentsOf: outputURL),
              let filtered = PDFDocument(data: filteredData),
              filtered.pageCount == original.pageCount
        else { throw CompressionError.filterFailed }
        progress(0.3)

        // Choose, page by page, between the filtered and the original page.
        let referenced = PageReferences.referencedPages(in: original)
        var chosen: [PDFPage] = []
        var compressed = 0, protected = 0, linked = 0
        for index in 0..<original.pageCount {
            guard let before = original.page(at: index), let after = filtered.page(at: index) else { continue }
            if referenced.contains(ObjectIdentifier(before)) {
                linked += 1
                chosen.append(before)
            } else if normalizedText(before) == normalizedText(after),
                      annotationSignature(before) == annotationSignature(after),
                      encodedSize(of: after) < encodedSize(of: before) {
                compressed += 1
                chosen.append(after)
            } else {
                if normalizedText(before) != normalizedText(after) || annotationSignature(before) != annotationSignature(after) {
                    protected += 1
                }
                chosen.append(before)
            }
            progress(0.3 + 0.6 * Double(index + 1) / Double(original.pageCount))
        }

        let filteredIndices = Set(chosen.indices.filter { chosen[$0] !== original.page(at: $0) })

        // Assemble in the original document so its outline and metadata are kept. A compressed page
        // takes over the original page's annotations: the filtered copies' links point into the
        // temporary filtered document.
        for (index, page) in chosen.enumerated() {
            guard let before = original.page(at: index), page !== before else { continue }
            for annotation in page.annotations { page.removeAnnotation(annotation) }
            for annotation in before.annotations {
                before.removeAnnotation(annotation)
                page.addAnnotation(annotation)
            }
            original.removePage(at: index)
            original.insert(page, at: index)
        }

        guard var data = original.dataRepresentation() else { throw CompressionError.filterFailed }
        // Replacing pages makes PDFKit redraw every page on save, which turns Type 3 text into
        // outlines; put back each page's own content (see PDFGraft).
        if compressed > 0 {
            let originalFile = SourceFile(source), filteredFile = SourceFile(filteredData)
            let sources = chosen.indices.map {
                PageSource(file: filteredIndices.contains($0) ? filteredFile : originalFile, index: $0)
            }
            if let restored = PDFGraft.restoreContents(of: data, sources: sources) { data = restored }
        }
        progress(1)
        return CompressionResult(
            data: data, originalSize: source.count,
            compressedPages: compressed, protectedPages: protected, linkedPages: linked
        )
    }

    private static func makeFilter(for level: CompressionLevel) throws -> URL {
        let s = level.settings
        let plist: [String: Any] = [
            "Name": "xPdf \(level.rawValue)",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": s.quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": [
                    "ImageResolution": s.dpi, "ImageScaleInterpolate": true,
                    "ImageSizeMax": s.maxSize, "ImageSizeMin": 0,
                ],
            ]]],
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xpdf-\(level.rawValue)-\(UUID().uuidString).qfilter")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    private static func normalizedText(_ page: PDFPage) -> String {
        (page.string ?? "").unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init).joined()
    }

    private static func annotationSignature(_ page: PDFPage) -> [String] {
        page.annotations.map { "\($0.type ?? "")|\($0.contents ?? "")|\($0.fieldName ?? "")" }
    }

    private static func encodedSize(of page: PDFPage) -> Int {
        let single = PDFDocument()
        guard let copy = page.copy() as? PDFPage else { return .max }
        single.insert(copy, at: 0)
        return single.dataRepresentation()?.count ?? .max
    }
}
