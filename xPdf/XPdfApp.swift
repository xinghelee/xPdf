import SwiftUI

@main
struct XPdfApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PDFFile() }) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            ViewerCommands()
            WelcomeCommands()
        }

        Window("欢迎使用 xPdf", id: WelcomeView.windowID) {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        .defaultLaunchBehavior(UserDefaults.standard.object(forKey: "welcome.showAtLaunch") as? Bool == false ? .suppressed : .presented)

        Settings {
            AISettingsView()
        }
    }
}

struct WelcomeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("欢迎使用 xPdf") { openWindow(id: WelcomeView.windowID) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Divider()
        }
    }
}
