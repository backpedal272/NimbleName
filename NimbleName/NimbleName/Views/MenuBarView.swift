import AppKit
import SwiftUI

struct MenuBarView: View {
    private var model: AppModel { AppModel.shared }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Button(readyLabel) { showMainWindow() }
        if model.isAnalyzing {
            Text("Analyzing…")
        }
        Divider()
        Toggle("Watch Folders", isOn: $model.settings.watchingEnabled)
        if !model.access.watchedFolders.isEmpty {
            Section("Watched folders") {
                ForEach(model.access.watchedFolders, id: \.self) { folder in
                    Text(folder.lastPathComponent)
                }
            }
        }
        Divider()
        Button("Open Nimble Name") { showMainWindow() }
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit Nimble Name") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var readyLabel: String {
        switch model.readyCount {
        case 0: "No files waiting for review"
        case 1: "1 file ready to rename"
        default: "\(model.readyCount) files ready to rename"
        }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
