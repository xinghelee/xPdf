import AppKit
import PDFKit
import zlib

/// Builds stamp annotations that show an image and are saved with the document.
///
/// PDFKit cannot give a new annotation an appearance stream, and a custom-drawn PDFAnnotation
/// subclass is not written to the file. It does keep the appearance streams of annotations it
/// reads, so the stamp is written as a one-page PDF (image XObject as the stamp's appearance) and
/// loaded with PDFKit. The annotation only survives saving into another document if its page has
/// been part of that document, which `ViewerModel.insertImage` takes care of.
enum ImageStamp {
    /// Longest side, in pixels, an inserted image is stored at.
    static let maxPixels = 2400

    /// Returns the stamp together with the one-page document that owns it (keep it alive).
    static func make(_ image: CGImage, size: CGSize) -> (PDFDocument, PDFAnnotation)? {
        let image = downscaled(image)
        guard let data = pdfData(image, size: size),
              let document = PDFDocument(data: data), let page = document.page(at: 0),
              let annotation = page.annotations.first else { return nil }
        return (document, annotation)
    }

    private static func downscaled(_ image: CGImage) -> CGImage {
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

    private static func pdfData(_ image: CGImage, size: CGSize) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, size.width > 0, size.height > 0 else { return nil }

        // Read the pixels as premultiplied RGBA in sRGB.
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let opaque = !stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] != 255 }

        var objects: [Data] = []
        func add(_ dictionary: String, stream: Data? = nil) {
            var object = Data(dictionary.utf8)
            if let stream {
                object.append(Data("\nstream\n".utf8))
                object.append(stream)
                object.append(Data("\nendstream".utf8))
            }
            objects.append(object)
        }
        let W = String(format: "%.4f", size.width), H = String(format: "%.4f", size.height)
        add("<< /Type /Catalog /Pages 2 0 R >>")
        add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(W) \(H)] /Annots [4 0 R] >>")
        add("<< /Type /Annot /Subtype /Stamp /Rect [0 0 \(W) \(H)] /F 4 /Name /xPdfImage /Contents (Image) /AP << /N 5 0 R >> >>")
        let content = Data("q \(W) 0 0 \(H) 0 0 cm /Im0 Do Q".utf8)
        add("<< /Type /XObject /Subtype /Form /BBox [0 0 \(W) \(H)] /Resources << /XObject << /Im0 6 0 R >> >> /Length \(content.count) >>",
            stream: content)

        let imageHeader = "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /BitsPerComponent 8"
        if opaque, let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.88]) {
            add("<< \(imageHeader) /ColorSpace /DeviceRGB /Filter /DCTDecode /Length \(jpeg.count) >>", stream: jpeg)
        } else {
            // Transparent image: color as Flate RGB plus a soft mask with the alpha channel.
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
            let color = deflate(Data(rgb)), mask = deflate(Data(alpha))
            add("<< \(imageHeader) /ColorSpace /DeviceRGB /Filter /FlateDecode /SMask 7 0 R /Length \(color.count) >>", stream: color)
            add("<< \(imageHeader) /ColorSpace /DeviceGray /Filter /FlateDecode /Length \(mask.count) >>", stream: mask)
        }

        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n".utf8))
            out.append(object)
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
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
