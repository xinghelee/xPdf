import SwiftUI

@main
struct XPdfApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PDFFile() }) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1280, height: 860)
        .commands { ViewerCommands() }
    }
}
