import AppKit
import SwiftUI

/// Receives files opened via Finder ("Open With"), the Dock icon, or `open -a`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("application(_:open:) received %d url(s)", urls.count)
        AppModel.shared.addURLs(urls)
    }
}

@main
struct NimbleNameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        WindowGroup("Nimble Name", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 480)
        }
        .defaultSize(width: 1150, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Files or Folders…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("Analyze Pending") { model.analyzePending() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.pendingCount == 0)
                Button("Rename Checked Files") { model.renameChecked() }
                    .keyboardShortcut("r")
                    .disabled(model.checkedCount == 0)
                Button("Undo Last Rename Batch") { model.undoLastBatch() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(!model.history.canUndo)
                Divider()
                Button("Preview") { model.previewSelection() }
                    .keyboardShortcut("y")
                    .disabled(model.selection.isEmpty)
            }
        }

        Settings {
            SettingsView()
        }

        Window("Rename History", id: "history") {
            HistoryView()
        }
        .defaultSize(width: 560, height: 520)

        MenuBarExtra(isInserted: Binding(
            get: { AppModel.shared.settings.showMenuBar },
            set: { AppModel.shared.settings.showMenuBar = $0 }
        )) {
            MenuBarView()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "doc.text.magnifyingglass")
                if model.readyCount > 0 {
                    Text("\(model.readyCount)")
                }
            }
        }
    }
}
