import Foundation
import PDFKit

// Once pages have been inserted, removed or reordered in a PDFDocument, PDFKit stops copying page
// content when it saves and instead redraws every page. Redrawing re-embeds fonts, and Type 3 fonts
// (which browsers use for most text) come out as plain outlines: the text looks the same but can no
// longer be searched, selected or copied. Even removing a page is enough to trigger this.
//
// PDFKit's output still has the right page order, rotation, annotations, outline and form fields;
// only the page content is damaged. So after such a save, each page whose origin is known gets its
// original content stream and resources back from that origin, and the file is rewritten with only
// the objects still in use.

/// The bytes of a document pages came from.
final class SourceFile {
    let data: Data

    init(_ data: Data) { self.data = data }

    /// The document as PDFKit writes it without structural changes: content is copied exactly, and
    /// the syntax is predictable (classic cross-reference table, no object streams).
    private(set) lazy var parser: PDFFileParser? = {
        guard let document = PDFDocument(data: data), !document.isEncrypted,
              let normalized = document.dataRepresentation() else { return nil }
        return PDFFileParser(normalized)
    }()
}

/// Where a page's untouched content lives: page `index` of `file`.
struct PageSource {
    let file: SourceFile
    let index: Int
}

enum PDFGraft {
    /// Returns `output` (a PDFKit-written document) with the content of each page `i` replaced by
    /// that of `sources[i]`, or nil if nothing could be restored (the caller keeps `output`).
    /// Pages without a source, or whose page boxes differ from their source, are left as they are.
    static func restoreContents(of output: Data, sources: [PageSource?]) -> Data? {
        guard sources.contains(where: { $0 != nil }),
              let base = PDFFileParser(output) else { return nil }
        let pages = base.pages()
        guard pages.count == sources.count else { return nil }

        var parsers: [PDFFileParser] = [base]
        var fileIDs: [ObjectIdentifier: Int] = [:]
        var overrides: [Int: PDFValue] = [:]

        for (index, source) in sources.enumerated() {
            guard let source, let parser = source.file.parser else { continue }
            let sourcePages = parser.pages()
            guard sourcePages.indices.contains(source.index) else { continue }
            let pageNumber = pages[index], sourceNumber = sourcePages[source.index]
            guard case .dict(var entries)? = base.object(pageNumber)?.value,
                  sameBoxes(base, pageNumber, parser, sourceNumber) else { continue }

            let fileID: Int
            if let id = fileIDs[ObjectIdentifier(source.file)] {
                fileID = id
            } else {
                fileID = parsers.count
                parsers.append(parser)
                fileIDs[ObjectIdentifier(source.file)] = fileID
            }
            entries.removeAll { ["/Contents", "/Resources", "/Group"].contains($0.0) }
            if let contents = parser.entry(sourceNumber, "/Contents") {
                entries.append(("/Contents", .foreign(fileID, contents)))
            }
            if let resources = parser.inherited(sourceNumber, "/Resources") {
                entries.append(("/Resources", .foreign(fileID, resources)))
            }
            if let group = parser.entry(sourceNumber, "/Group") {
                entries.append(("/Group", .foreign(fileID, group)))
            }
            overrides[pageNumber] = .dict(entries)
        }
        guard !overrides.isEmpty else { return nil }
        return PDFWriter(files: parsers, overrides: overrides).write(trailer: base.trailer)
    }

    private static func sameBoxes(_ a: PDFFileParser, _ pageA: Int, _ b: PDFFileParser, _ pageB: Int) -> Bool {
        func box(_ parser: PDFFileParser, _ page: Int, _ key: String) -> [Double]? {
            guard let value = parser.inherited(page, key), case .array(let items) = parser.resolve(value) else { return nil }
            let numbers = items.compactMap { item -> Double? in
                guard case .token(let raw) = parser.resolve(item) else { return nil }
                return Double(String(decoding: raw, as: UTF8.self))
            }
            return numbers.count == 4 ? numbers : nil
        }
        func close(_ x: [Double]?, _ y: [Double]?) -> Bool {
            guard let x, let y else { return x == nil && y == nil }
            return zip(x, y).allSatisfy { abs($0 - $1) < 0.01 }
        }
        let mediaA = box(a, pageA, "/MediaBox"), mediaB = box(b, pageB, "/MediaBox")
        guard mediaA != nil, close(mediaA, mediaB) else { return false }
        return close(box(a, pageA, "/CropBox") ?? mediaA, box(b, pageB, "/CropBox") ?? mediaB)
    }
}

// MARK: - Parsing

indirect enum PDFValue {
    /// Number, boolean, null, name or string, kept exactly as written.
    case token(Data)
    case array([PDFValue])
    /// Keys include the leading slash, as written.
    case dict([(String, PDFValue)])
    case ref(Int)
    /// A value whose references belong to another file (used when grafting).
    case foreign(Int, PDFValue)
}

struct PDFObject {
    var value: PDFValue
    var stream: Data?
}

/// A reader for PDFs as PDFKit writes them: a classic cross-reference table (incremental updates
/// allowed), plain indirect objects, no encryption.
final class PDFFileParser {
    private let bytes: [UInt8]
    private var offsets: [Int: Int] = [:]
    private var cache: [Int: PDFObject] = [:]
    private var pageList: [Int]?
    private(set) var trailer: [(String, PDFValue)] = []

    init?(_ data: Data) {
        bytes = [UInt8](data)
        guard let start = lastIndex(of: "startxref") else { return nil }
        var i = start + 9
        guard var offset = readInt(&i) else { return nil }
        var visited = Set<Int>()
        var isLatest = true
        while visited.insert(offset).inserted {
            var j = offset
            guard word(&j) == "xref" else { return nil }
            while true {
                skipSpace(&j)
                var k = j
                if word(&k) == "trailer" { j = k; break }
                guard let firstNumber = readInt(&j), let count = readInt(&j) else { return nil }
                for n in firstNumber..<(firstNumber + count) {
                    guard let at = readInt(&j), readInt(&j) != nil else { return nil }
                    let kind = word(&j)
                    if kind == "n", offsets[n] == nil { offsets[n] = at }
                }
            }
            guard case .dict(let dictionary)? = parseValue(&j) else { return nil }
            if isLatest {
                trailer = dictionary
                isLatest = false
                // Encrypted strings and streams are keyed to object numbers, which grafting changes.
                if dictionary.contains(where: { $0.0 == "/Encrypt" || $0.0 == "/XRefStm" }) { return nil }
            }
            guard let previous = dictionary.first(where: { $0.0 == "/Prev" })?.1,
                  case .token(let raw) = previous, let next = Int(String(decoding: raw, as: UTF8.self)) else { break }
            offset = next
        }
        guard !trailer.isEmpty else { return nil }
    }

    func object(_ number: Int) -> PDFObject? {
        if let cached = cache[number] { return cached }
        guard let offset = offsets[number], offset < bytes.count else { return nil }
        var i = offset
        guard readInt(&i) == number, readInt(&i) != nil, word(&i) == "obj",
              let value = parseValue(&i) else { return nil }
        var object = PDFObject(value: value, stream: nil)
        var j = i
        if word(&j) == "stream", case .dict(let entries) = value {
            if j < bytes.count, bytes[j] == 0x0D { j += 1 }
            if j < bytes.count, bytes[j] == 0x0A { j += 1 }
            guard let lengthValue = entries.first(where: { $0.0 == "/Length" })?.1,
                  case .token(let raw) = resolve(lengthValue),
                  let length = Int(String(decoding: raw, as: UTF8.self)),
                  length >= 0, j + length <= bytes.count else { return nil }
            object.stream = Data(bytes[j..<(j + length)])
        }
        cache[number] = object
        return object
    }

    func resolve(_ value: PDFValue) -> PDFValue {
        var value = value
        var hops = 0
        while case .ref(let number) = value, hops < 32 {
            guard let object = object(number) else { return .token(Data("null".utf8)) }
            value = object.value
            hops += 1
        }
        return value
    }

    func entry(_ number: Int, _ key: String) -> PDFValue? {
        guard case .dict(let entries)? = object(number)?.value else { return nil }
        return entries.first { $0.0 == key }?.1
    }

    /// `key` on the page or, for inheritable attributes, on its nearest ancestor that has it.
    func inherited(_ number: Int, _ key: String) -> PDFValue? {
        var current = number
        var visited = Set<Int>()
        while visited.insert(current).inserted {
            if let value = entry(current, key) { return value }
            guard case .ref(let parent)? = entry(current, "/Parent") else { return nil }
            current = parent
        }
        return nil
    }

    /// Object numbers of the page objects, in order.
    func pages() -> [Int] {
        if let pageList { return pageList }
        var result: [Int] = []
        var visited = Set<Int>()
        func walk(_ number: Int, depth: Int) {
            guard depth < 64, visited.insert(number).inserted,
                  case .dict(let entries)? = object(number)?.value else { return }
            let type = entries.first { $0.0 == "/Type" }.map { resolve($0.1) }
            if case .token(let raw)? = type, raw == Data("/Pages".utf8) {
                guard case .array(let kids)? = entries.first(where: { $0.0 == "/Kids" }).map({ resolve($0.1) }) else { return }
                for case .ref(let kid) in kids { walk(kid, depth: depth + 1) }
            } else {
                result.append(number)
            }
        }
        if case .ref(let root)? = trailer.first(where: { $0.0 == "/Root" })?.1,
           case .ref(let tree)? = entry(root, "/Pages") {
            walk(tree, depth: 0)
        }
        pageList = result
        return result
    }

    // MARK: Lexing

    private static func isSpace(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    private static func isDelimiter(_ c: UInt8) -> Bool {
        c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25
    }

    private func skipSpace(_ i: inout Int) {
        while i < bytes.count {
            if Self.isSpace(bytes[i]) {
                i += 1
            } else if bytes[i] == 0x25 { // comment
                while i < bytes.count, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
            } else {
                break
            }
        }
    }

    /// A run of regular characters.
    private func word(_ i: inout Int) -> String {
        skipSpace(&i)
        let start = i
        while i < bytes.count, !Self.isSpace(bytes[i]), !Self.isDelimiter(bytes[i]) { i += 1 }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private func readInt(_ i: inout Int) -> Int? {
        var j = i
        guard let value = Int(word(&j)) else { return nil }
        i = j
        return value
    }

    private func parseValue(_ i: inout Int) -> PDFValue? {
        skipSpace(&i)
        guard i < bytes.count else { return nil }
        let c = bytes[i]
        if c == 0x3C, i + 1 < bytes.count, bytes[i + 1] == 0x3C { // <<
            i += 2
            var entries: [(String, PDFValue)] = []
            while true {
                skipSpace(&i)
                guard i + 1 < bytes.count else { return nil }
                if bytes[i] == 0x3E, bytes[i + 1] == 0x3E { i += 2; break }
                guard bytes[i] == 0x2F, case .token(let key)? = parseValue(&i), let value = parseValue(&i) else { return nil }
                entries.append((String(decoding: key, as: UTF8.self), value))
            }
            return .dict(entries)
        }
        if c == 0x3C { // hex string
            let start = i
            while i < bytes.count, bytes[i] != 0x3E { i += 1 }
            i += 1
            return .token(Data(bytes[start..<min(i, bytes.count)]))
        }
        if c == 0x5B { // [
            i += 1
            var items: [PDFValue] = []
            while true {
                skipSpace(&i)
                guard i < bytes.count else { return nil }
                if bytes[i] == 0x5D { i += 1; break }
                guard let item = parseValue(&i) else { return nil }
                items.append(item)
            }
            return .array(items)
        }
        if c == 0x28 { // literal string
            let start = i
            var depth = 0
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x5C { i += 2; continue }
                if b == 0x28 { depth += 1 }
                if b == 0x29 { depth -= 1; if depth == 0 { i += 1; break } }
                i += 1
            }
            return .token(Data(bytes[start..<min(i, bytes.count)]))
        }
        if c == 0x2F { // name
            let start = i
            i += 1
            while i < bytes.count, !Self.isSpace(bytes[i]), !Self.isDelimiter(bytes[i]) { i += 1 }
            return .token(Data(bytes[start..<i]))
        }
        // Number, keyword or reference ("12 0 R").
        let start = i
        let first = word(&i)
        guard !first.isEmpty else { return nil }
        if let number = Int(first), number >= 0 {
            var j = i
            if let _ = readInt(&j) {
                var k = j
                if word(&k) == "R" { i = k; return .ref(number) }
            }
        }
        return .token(Data(bytes[start..<i]))
    }

    private func lastIndex(of text: String) -> Int? {
        let needle = Array(text.utf8)
        var i = bytes.count - needle.count
        while i >= 0 {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle { return i }
            i -= 1
        }
        return nil
    }
}

// MARK: - Writing

/// Writes a new file containing the objects reachable from `trailer` in `files[0]`, with
/// `overrides` replacing objects of `files[0]` and `.foreign` values pulling objects from other files.
private final class PDFWriter {
    private let files: [PDFFileParser]
    private let overrides: [Int: PDFValue]
    private var numbers: [[Int: Int]]
    private var queue: [(file: Int, number: Int)] = []
    private var next = 1

    init(files: [PDFFileParser], overrides: [Int: PDFValue]) {
        self.files = files
        self.overrides = overrides
        numbers = Array(repeating: [:], count: files.count)
    }

    func write(trailer: [(String, PDFValue)]) -> Data? {
        var trailerText = Data()
        for (key, value) in trailer where ["/Root", "/Info", "/ID"].contains(key) {
            trailerText.append(Data(" \(key) ".utf8))
            serialize(value, file: 0, into: &trailerText)
        }

        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        var index = 0
        while index < queue.count {
            let (file, number) = queue[index]
            index += 1
            offsets.append(out.count)
            out.append(Data("\(numbers[file][number]!) 0 obj\n".utf8))
            if file == 0, let override = overrides[number] {
                serialize(override, file: 0, into: &out)
            } else if let object = files[file].object(number) {
                if let stream = object.stream, case .dict(var entries) = object.value {
                    entries.removeAll { $0.0 == "/Length" }
                    entries.append(("/Length", .token(Data("\(stream.count)".utf8))))
                    serialize(.dict(entries), file: file, into: &out)
                    out.append(Data("\nstream\n".utf8))
                    out.append(stream)
                    out.append(Data("\nendstream".utf8))
                } else {
                    serialize(object.value, file: file, into: &out)
                }
            } else {
                out.append(Data("null".utf8))
            }
            out.append(Data("\nendobj\n".utf8))
        }

        let xref = out.count
        var table = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        out.append(Data(table.utf8))
        out.append(Data("trailer\n<< /Size \(offsets.count + 1)".utf8))
        out.append(trailerText)
        out.append(Data(" >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    private func number(for file: Int, _ number: Int) -> Int {
        if let assigned = numbers[file][number] { return assigned }
        let assigned = next
        next += 1
        numbers[file][number] = assigned
        queue.append((file, number))
        return assigned
    }

    private func serialize(_ value: PDFValue, file: Int, into out: inout Data) {
        switch value {
        case .token(let raw):
            out.append(raw)
        case .ref(let target):
            out.append(Data("\(number(for: file, target)) 0 R".utf8))
        case .array(let items):
            out.append(Data("[".utf8))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(0x20) }
                serialize(item, file: file, into: &out)
            }
            out.append(Data("]".utf8))
        case .dict(let entries):
            out.append(Data("<<".utf8))
            for (key, item) in entries {
                out.append(Data(" \(key) ".utf8))
                serialize(item, file: file, into: &out)
            }
            out.append(Data(" >>".utf8))
        case .foreign(let other, let inner):
            serialize(inner, file: other, into: &out)
        }
    }
}
