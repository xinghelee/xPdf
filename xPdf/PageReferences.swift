import PDFKit

/// Pages that bookmarks or link annotations point to.
///
/// PDFKit keeps these references as they were read from the file: if the target page object is
/// replaced, saving writes a reference to the wrong page, and it does not save destinations that
/// are changed or created in code. So a page in this set must never be swapped for a rebuilt copy
/// (OCR, compression), or the bookmarks and links leading to it break.
enum PageReferences {
    static func referencedPages(in document: PDFDocument) -> Set<ObjectIdentifier> {
        var pages = Set<ObjectIdentifier>()
        func add(_ destination: PDFDestination?) {
            if let page = destination?.page { pages.insert(ObjectIdentifier(page)) }
        }
        func walk(_ node: PDFOutline, depth: Int) {
            add(node.destination)
            add((node.action as? PDFActionGoTo)?.destination)
            guard depth < 64 else { return }
            for i in 0..<node.numberOfChildren {
                if let child = node.child(at: i) { walk(child, depth: depth + 1) }
            }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                add(annotation.destination)
                add((annotation.action as? PDFActionGoTo)?.destination)
            }
        }
        return pages
    }
}
