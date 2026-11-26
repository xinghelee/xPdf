import PDFKit
import Vision
import CoreText

/// A recognized line of text. `box` is normalized (0–1, bottom-left origin) in the page's
/// displayed orientation, as Vision reports it.
struct OCRLine {
    let text: String
    let box: CGRect
}

enum OCRLanguage: String, CaseIterable, Identifiable {
    case chineseEnglish, english, japanese, korean
    var id: Self { self }

    var title: String {
        switch self {
        case .chineseEnglish: "中文和英文"
        case .english: "英文"
        case .japanese: "日文"
        case .korean: "韩文"
        }
    }

    var codes: [String] {
        switch self {
        case .chineseEnglish: ["zh-Hans", "zh-Hant", "en-US"]
        case .english: ["en-US"]
        case .japanese: ["ja-JP", "en-US"]
        case .korean: ["ko-KR", "en-US"]
        }
    }
}

enum OCREngine {
    /// Whether the page's content stream actually draws text (including inside form XObjects).
    /// `PDFPage.string` is not reliable for this: PDFView runs its own OCR on displayed image pages,
    /// so scans start reporting text as soon as they are shown.
    static func hasTextContent(_ page: PDFPage) -> Bool {
        guard let pageRef = page.pageRef, let table = CGPDFOperatorTableCreate() else { return false }
        for op in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                info?.assumingMemoryBound(to: TextScan.self).pointee.found = true
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let scan = info.assumingMemoryBound(to: TextScan.self)
            guard !scan.pointee.found, scan.pointee.depth < 8, scan.pointee.budget > 0 else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let parent = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            // A form that is drawn many times (or draws itself) only needs scanning once; whether it
            // contains text does not depend on where it is used. Without this a crafted file can make
            // the scan grow exponentially with nesting depth.
            guard scan.pointee.visited.insert(stream).inserted else { return }
            scan.pointee.budget -= 1
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Form" else { return }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return }
            let child = CGPDFContentStreamCreateWithStream(stream, resources, parent)
            scan.pointee.depth += 1
            let childScanner = CGPDFScannerCreate(child, scan.pointee.table, info)
            CGPDFScannerScan(childScanner)
            scan.pointee.depth -= 1
        }
        var scan = TextScan(table: table)
        let content = CGPDFContentStreamCreateWithPage(pageRef)
        withUnsafeMutablePointer(to: &scan) { pointer in
            let scanner = CGPDFScannerCreate(content, table, pointer)
            CGPDFScannerScan(scanner)
        }
        return scan.found
    }

    private struct TextScan {
        let table: CGPDFOperatorTableRef
        var found = false
        var depth = 0
        var visited: Set<CGPDFStreamRef> = []
        /// Upper bound on form XObjects scanned per page.
        var budget = 256
    }

    /// Page geometry: the crop box in page space, the transform from (crop-box-relative) page space
    /// to the displayed orientation, and the displayed size.
    static func geometry(of page: PDFPage, rotation: Int) -> (box: CGRect, transform: CGAffineTransform, size: CGSize) {
        let box = page.bounds(for: .cropBox)
        let w = box.width, h = box.height
        switch ((rotation % 360) + 360) % 360 {
        case 90: return (box, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w), CGSize(width: h, height: w))
        case 180: return (box, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h), CGSize(width: w, height: h))
        case 270: return (box, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0), CGSize(width: h, height: w))
        default: return (box, .identity, CGSize(width: w, height: h))
        }
    }

    /// Renders the page as it is displayed (with `rotation` applied) at roughly 300 dpi.
    static func renderImage(of page: PDFPage, rotation: Int) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let (box, transform, size) = geometry(of: page, rotation: rotation)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(300.0 / 72.0, 4200 / max(size.width, size.height))
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(transform)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(pageRef)
        return ctx.makeImage()
    }

    /// Runs text recognition. Safe to call off the main thread.
    static func recognize(_ image: CGImage, languages: [String]) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return OCRLine(text: candidate.string, box: observation.boundingBox)
        }
    }

    /// Builds a page whose content is `page`'s content plus an invisible text layer, displayed with
    /// `rotation`. Returns the new page together with the document that owns it (keep it alive).
    static func makeSearchablePage(from page: PDFPage, rotation: Int, lines: [OCRLine]) -> (PDFDocument, PDFPage)? {
        guard let pageRef = page.pageRef else { return nil }
        let (box, transform, size) = geometry(of: page, rotation: rotation)
        var mediaBox = page.bounds(for: .mediaBox)
        var cropBox = box
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData,
            kCGPDFContextCropBox: Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size) as CFData,
        ]
        ctx.beginPDFPage(pageInfo as CFDictionary)
        ctx.drawPDFPage(pageRef)

        // Draw the text in the displayed orientation so it lines up with what Vision saw.
        ctx.saveGState()
        ctx.translateBy(x: box.minX, y: box.minY)
        ctx.concatenate(transform.inverted())
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(
                x: line.box.minX * size.width, y: line.box.minY * size.height,
                width: line.box.width * size.width, height: line.box.height * size.height
            )
            draw(line.text, fitting: rect, in: ctx)
        }
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()

        guard let document = PDFDocument(data: data as Data), let newPage = document.page(at: 0) else { return nil }
        newPage.rotation = rotation
        return (document, newPage)
    }

    /// Font for the invisible text layer. It must map every glyph back to the right character when
    /// embedded: the system UI font's CJK fallback shares glyphs between common hanzi and Kangxi
    /// radicals (页 comes back as ⻚), breaking search. Arial Unicode covers CJK, kana and hangul in
    /// one font without that problem; PingFang SC is the fallback.
    private static let textLayerFont: CTFont = {
        for name in ["ArialUnicodeMS", "PingFangSC-Regular"] {
            let font = CTFontCreateWithName(name as CFString, 10, nil)
            if CTFontCopyPostScriptName(font) as String == name { return font }
        }
        return CTFontCreateWithName("Helvetica" as CFString, 10, nil)
    }()

    /// Draws one line so its glyphs span `rect`: font height matches the box, width is stretched to fit.
    private static func draw(_ text: String, fitting rect: CGRect, in ctx: CGContext) {
        let base = textLayerFont
        guard rect.width > 1, rect.height > 1 else { return }
        let unitHeight = (CTFontGetAscent(base) + CTFontGetDescent(base)) / 10
        let font = CTFontCreateCopyWithAttributes(base, rect.height / unitHeight, nil, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + CTFontGetDescent(font))
        ctx.scaleBy(x: rect.width / width, y: 1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
