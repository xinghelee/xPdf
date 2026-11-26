import AppKit
import PDFKit
import zlib

/// An image placed on a page, as a stamp annotation.
///
/// PDFKit cannot give an annotation it writes an appearance stream of our own, so while editing the
/// image is drawn by `draw(with:in:)`, and when the document is saved `ImageStamp.embedAppearances`
/// appends an incremental update that gives the written stamp the image as its /AP. (Inserting a page
/// from another document to carry the appearance across makes PDFKit redraw every page on save,
/// which turns Type 3 text — common in browser-made PDFs — into outlines.) Once reopened, the stamp
/// is an ordinary annotation with an appearance stream, which PDFKit keeps.
final class ImageStampAnnotation: PDFAnnotation {
    private(set) var image: CGImage?
    private(set) var encoded: ImageStamp.EncodedImage?

    /// `image` is in page space (already counter-rotated for a rotated page).
    init(image: CGImage, bounds: CGRect) {
        let image = ImageStamp.downscaled(image)
        self.image = image
        self.encoded = ImageStamp.encode(image)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        setValue("xpdf-img-\(UUID().uuidString)", forAnnotationKey: .name)
        contents = "图片"
    }

    override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable: Any]?) {
        super.init(bounds: bounds, forType: annotationType, withProperties: properties)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    var identifier: String? { value(forAnnotationKey: .name) as? String }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image else { return super.draw(with: box, in: context) }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

enum ImageStamp {
    /// Longest side, in pixels, an inserted image is stored at.
    static let maxPixels = 2400

    struct EncodedImage {
        let width: Int
        let height: Int
        /// JPEG data (DCTDecode) for opaque images, zlib RGB (FlateDecode) otherwise.
        let color: Data
        let isJPEG: Bool
        /// zlib alpha channel for transparent images.
        let mask: Data?
    }

    static func downscaled(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixels else { return image }
        let scale = Double(maxPixels) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func encode(_ image: CGImage) -> EncodedImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let opaque = !stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] != 255 }
        if opaque, let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.88]) {
            return EncodedImage(width: w, height: h, color: jpeg, isJPEG: true, mask: nil)
        }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let a = Int(rgba[i * 4 + 3])
            alpha[i] = UInt8(a)
            for c in 0..<3 {
                let v = Int(rgba[i * 4 + c])
                rgb[i * 3 + c] = a == 0 ? 255 : UInt8(min(255, (v * 255 + a / 2) / a))
            }
        }
        return EncodedImage(width: w, height: h, color: deflate(Data(rgb)), isJPEG: false, mask: deflate(Data(alpha)))
    }

    // MARK: - Saving

    /// The image stamps placed in `documents` that still need their appearance written, by /NM.
    static func pendingStamps(in documents: [PDFDocument]) -> [String: ImageStampAnnotation] {
        var stamps: [String: ImageStampAnnotation] = [:]
        for document in documents {
            for index in 0..<document.pageCount {
                for case let stamp as ImageStampAnnotation in document.page(at: index)?.annotations ?? [] {
                    if let id = stamp.identifier, stamp.encoded != nil { stamps[id] = stamp }
                }
            }
        }
        return stamps
    }

    /// Appends an incremental update to `data` (as written by PDFKit) that gives each stamp in
    /// `stamps` its image as the appearance. Nothing else in the file is touched. Returns `data`
    /// unchanged if it cannot be patched.
    static func embedAppearances(in data: Data, stamps: [String: ImageStampAnnotation]) -> Data {
        guard !stamps.isEmpty else { return data }
        let bytes = [UInt8](data)
        guard let trailerStart = lastRange(of: "trailer", in: bytes),
              let startxrefRange = lastRange(of: "startxref", in: bytes),
              trailerStart < startxrefRange else { return data }
        let trailer = latin1(bytes[trailerStart..<startxrefRange])
        guard let size = firstInt(after: "/Size", in: trailer),
              let previous = Int(latin1(bytes[startxrefRange + 9..<bytes.count])
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber }) else { return data }

        var nextNumber = size
        var objects: [(number: Int, body: Data)] = []
        for (id, stamp) in stamps {
            guard let image = stamp.encoded,
                  let (number, dictionary) = annotationObject(named: id, in: bytes) else { continue }
            let formNumber = nextNumber, imageNumber = nextNumber + 1, maskNumber = nextNumber + 2
            nextNumber += image.mask == nil ? 2 : 3

            var updated = removeEntry("/AAPL:AKExtras", from: removeEntry("/AP", from: dictionary))
            guard let open = updated.range(of: "<<") else { continue }
            updated.insert(contentsOf: " /AP << /N \(formNumber) 0 R >>", at: open.upperBound)
            objects.append((number, Data(updated.data(using: .isoLatin1) ?? Data())))

            let w = String(format: "%.4f", stamp.bounds.width), h = String(format: "%.4f", stamp.bounds.height)
            let content = Data("q \(w) 0 0 \(h) 0 0 cm /Im0 Do Q".utf8)
            objects.append((formNumber, stream(
                "<< /Type /XObject /Subtype /Form /BBox [0 0 \(w) \(h)] /Resources << /XObject << /Im0 \(imageNumber) 0 R >> >> /Length \(content.count) >>",
                content)))
            let header = "/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /BitsPerComponent 8 /ColorSpace /DeviceRGB"
            let filter = image.isJPEG ? "/DCTDecode" : "/FlateDecode"
            let mask = image.mask == nil ? "" : " /SMask \(maskNumber) 0 R"
            objects.append((imageNumber, stream("<< \(header) /Filter \(filter)\(mask) /Length \(image.color.count) >>", image.color)))
            if let alpha = image.mask {
                objects.append((maskNumber, stream(
                    "<< /Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode /Length \(alpha.count) >>",
                    alpha)))
            }
        }
        guard !objects.isEmpty else { return data }

        var out = data
        if bytes.last != 0x0A { out.append(0x0A) }
        var offsets: [Int: Int] = [:]
        for object in objects {
            offsets[object.number] = out.count
            out.append(Data("\(object.number) 0 obj\n".utf8))
            out.append(object.body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        var xref = "xref\n"
        for (number, offset) in offsets.sorted(by: { $0.key < $1.key }) {
            xref += "\(number) 1\n" + String(format: "%010d 00000 n \n", offset)
        }
        var newTrailer = trailer
            .replacingOccurrences(of: #"/Size\s+\d+"#, with: "/Size \(nextNumber)", options: .regularExpression)
            .replacingOccurrences(of: #"/Prev\s+\d+"#, with: "", options: .regularExpression)
        if let open = newTrailer.range(of: "<<") {
            newTrailer.insert(contentsOf: " /Prev \(previous)", at: open.upperBound)
        }
        xref += newTrailer.trimmingCharacters(in: .whitespacesAndNewlines) + "\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(xref.data(using: .isoLatin1) ?? Data())
        return out
    }

    // MARK: - PDF text helpers

    private static func stream(_ dictionary: String, _ content: Data) -> Data {
        var data = Data(dictionary.utf8)
        data.append(Data("\nstream\n".utf8))
        data.append(content)
        data.append(Data("\nendstream".utf8))
        return data
    }

    private static func latin1(_ slice: ArraySlice<UInt8>) -> String {
        String(bytes: slice, encoding: .isoLatin1) ?? ""
    }

    private static func firstInt(after key: String, in text: String) -> Int? {
        guard let range = text.range(of: key + #"\s+(\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst(key.count).trimmingCharacters(in: .whitespaces))
    }

    private static func lastRange(of pattern: String, in bytes: [UInt8]) -> Int? {
        let needle = Array(pattern.utf8)
        guard bytes.count >= needle.count else { return nil }
        var i = bytes.count - needle.count
        while i >= 0 {
            if bytes[i] == needle[0], Array(bytes[i..<i + needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }

    /// Finds the object whose dictionary carries `/NM (name)`; returns its number and dictionary text.
    private static func annotationObject(named name: String, in bytes: [UInt8]) -> (Int, String)? {
        let needle = Array("/NM (\(name))".utf8)
        guard let hit = firstIndex(of: needle, in: bytes) else { return nil }
        // The object header is the last "obj" before the hit with no "endobj" in between.
        let window = latin1(bytes[max(0, hit - 4096)..<hit])
        let pattern = try! NSRegularExpression(pattern: #"(\d+)\s+0\s+obj\b"#)
        guard let match = pattern.matches(in: window, range: NSRange(window.startIndex..., in: window)).last,
              let header = Range(match.range, in: window),
              let numberRange = Range(match.range(at: 1), in: window),
              !window[header.upperBound...].contains("endobj"),
              let number = Int(window[numberRange]) else { return nil }
        // Latin-1 maps each byte to one scalar, so scalar distances are byte distances.
        let bodyStart = hit - window.unicodeScalars.distance(from: header.upperBound, to: window.endIndex)
        guard let end = firstIndex(of: Array("endobj".utf8), in: bytes, from: hit) else { return nil }
        let body = latin1(bytes[bodyStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("<<"), body.hasSuffix(">>") else { return nil }
        return (number, body)
    }

    private static func firstIndex(of needle: [UInt8], in bytes: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        var i = start
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0], Array(bytes[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Removes `key` and its value (a dictionary, or a single token) from a dictionary's text.
    private static func removeEntry(_ key: String, from dictionary: String) -> String {
        var text = dictionary
        var search = text.startIndex
        while let range = text.range(of: key, range: search..<text.endIndex) {
            // Only a whole key: the next character must not continue the name.
            if range.upperBound < text.endIndex, let next = text[range.upperBound].unicodeScalars.first,
               CharacterSet.alphanumerics.contains(next) || next == ":" || next == "_" {
                search = range.upperBound
                continue
            }
            var i = range.upperBound
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            var end = i
            if text[i...].hasPrefix("<<") {
                var depth = 0
                var j = i
                while j < text.endIndex {
                    if text[j...].hasPrefix("<<") { depth += 1; j = text.index(j, offsetBy: 2); continue }
                    if text[j...].hasPrefix(">>") {
                        depth -= 1; j = text.index(j, offsetBy: 2)
                        if depth == 0 { break }
                        continue
                    }
                    if text[j] == "(" {
                        // Skip a literal string, which may contain unbalanced brackets.
                        var level = 0
                        while j < text.endIndex {
                            let c = text[j]
                            if c == "\\" { j = text.index(after: j) }
                            else if c == "(" { level += 1 }
                            else if c == ")" { level -= 1; if level == 0 { break } }
                            if j < text.endIndex { j = text.index(after: j) }
                        }
                        if j < text.endIndex { j = text.index(after: j) }
                        continue
                    }
                    j = text.index(after: j)
                }
                end = j
            } else {
                while end < text.endIndex, !text[end].isWhitespace, text[end] != "/", text[end] != ">" {
                    end = text.index(after: end)
                }
            }
            text.removeSubrange(range.lowerBound..<end)
            search = range.lowerBound
        }
        return text
    }

    /// zlib-wrapped deflate, as FlateDecode expects.
    private static func deflate(_ input: Data) -> Data {
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return Data()
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, UInt(input.count))))
        let produced: Int = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                _ = zlib.deflate(&stream, Z_FINISH)
                return Int(stream.total_out)
            }
        }
        output.count = produced
        return output
    }
}
