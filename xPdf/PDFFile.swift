import SwiftUI
import PDFKit
import UniformTypeIdentifiers

final class PDFFile: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    let pdf: PDFDocument
    /// The file as it was read, for a never-displayed copy of the pages (see ViewerModel.pristinePages).
    let originalData: Data?
    /// Produces the file contents: commits in-progress edits (e.g. a form field being typed in) and
    /// works around PDFKit's limits when saving (see ViewerModel.currentDocumentData).
    /// The argument says whether pending UI edits may be committed (main thread only).
    var serialize: ((Bool) -> Data?)?

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
        // SwiftUI may ask for the snapshot on a background thread while the main thread waits for it,
        // so the model cannot be asked to do anything on the main thread here. Committing an
        // in-progress form edit needs the main thread and is only done when called there.
        let data = serialize?(Thread.isMainThread) ?? pdf.dataRepresentation().map {
            ImageStamp.embedAppearances(in: $0, stamps: ImageStamp.pendingStamps(in: [pdf]))
        }
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
