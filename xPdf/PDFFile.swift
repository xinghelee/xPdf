import SwiftUI
import PDFKit
import UniformTypeIdentifiers

final class PDFFile: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    let pdf: PDFDocument
    /// The file as it was read, for a never-displayed copy of the pages (see ViewerModel.pristinePages).
    let originalData: Data?
    /// Called before saving so in-progress edits (e.g. a form field being typed in) are committed.
    var commitPendingEdits: (() -> Void)?

    init() {
        pdf = PDFDocument()
        originalData = nil
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let doc = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        pdf = doc
        originalData = data
    }

    func snapshot(contentType: UTType) throws -> Data {
        if Thread.isMainThread { commitPendingEdits?() }
        guard let data = pdf.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Inserted images get their appearance in an incremental update (see ImageStampAnnotation).
        return ImageStamp.embedAppearances(in: data, stamps: ImageStamp.pendingStamps(in: [pdf]))
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
