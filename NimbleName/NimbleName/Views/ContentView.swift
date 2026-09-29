import OSLog
import SwiftUI
import UniformTypeIdentifiers

nonisolated private let log = Logger(subsystem: "pm.ad0.NimbleName", category: "drop")

struct ContentView: View {
    private var model: AppModel { AppModel.shared }
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.items.isEmpty {
                EmptyStateView()
            } else {
                ReviewTable()
            }
        }
        // The whole content area below the toolbar accepts drops, whatever it currently shows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            DropZoneFrame(isTargeted: isDropTargeted, alwaysVisible: model.items.isEmpty)
        }
        .toolbar { toolbarContent }
        .navigationSubtitle(subtitle)
        .sheet(isPresented: Binding(
            get: { model.previewItemID != nil },
            set: { if !$0 { model.previewItemID = nil } }
        )) {
            PreviewView()
        }
        .alert("Nimble Name", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    /// Finder puts each dragged file on the pasteboard as `public.file-url`. Reading that flavour at drop
    /// time is what grants a sandboxed app access to the file, so the URLs are loaded here rather than
    /// through `dropDestination(for: URL.self)`, which does not reliably accept Finder drags of documents.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        log.notice("drop: \(providers.count) item(s), \(candidates.count) with file URLs; types \(providers.map(\.registeredTypeIdentifiers).description, privacy: .public)")
        guard !candidates.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in candidates {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            log.notice("drop: resolved \(urls.count) url(s)")
            model.addURLs(urls)
        }
        return true
    }

    nonisolated private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                let url: URL? = switch item {
                case let url as URL: url
                case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
                case let string as String: URL(string: string)
                default: nil
                }
                if url == nil {
                    log.error("drop: could not read file URL: \(error?.localizedDescription ?? "no item", privacy: .public)")
                }
                continuation.resume(returning: url)
            }
        }
    }

    private var subtitle: String {
        if model.items.isEmpty { return "" }
        var parts: [String] = ["\(model.items.count) files"]
        if model.isAnalyzing { parts.append("analyzing…") }
        if model.readyCount > 0 { parts.append("\(model.readyCount) ready") }
        if model.renamedCount > 0 { parts.append("\(model.renamedCount) renamed") }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Add", systemImage: "plus") { model.presentOpenPanel() }
                .help("Add files or folders (⌘O)")

            Button("Analyze", systemImage: "sparkles") { model.analyzePending() }
                .disabled(model.pendingCount == 0)
                .help("Analyze pending files")

            Button("Rename \(model.checkedCount)", systemImage: "pencil.line") { model.renameChecked() }
                .disabled(model.checkedCount == 0)
                .help("Rename checked files (⌘R)")

            Button("Undo", systemImage: "arrow.uturn.backward") { model.undoLastBatch() }
                .disabled(!model.history.canUndo)
                .help("Undo the last rename batch")

            Button("Clear Done", systemImage: "checkmark.circle") { model.clearRenamed() }
                .disabled(model.renamedCount == 0)
                .help("Remove renamed and skipped files from the list")

            Toggle("Watch", systemImage: model.settings.watchingEnabled ? "eye" : "eye.slash", isOn: $model.settings.watchingEnabled)
                .help("Watch folders for new documents")

            Button("History", systemImage: "clock") { openWindow(id: "history") }
                .help("Show rename history")
        }
    }
}

/// Frame marking the drop zone. Dashed and subtle while idle (empty state only), solid accent-coloured
/// with a tinted background while a drag hovers over the window.
struct DropZoneFrame: View {
    let isTargeted: Bool
    let alwaysVisible: Bool

    var body: some View {
        if isTargeted || alwaysVisible {
            let shape = RoundedRectangle(cornerRadius: 12)
            ZStack {
                shape.fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                shape.strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isTargeted ? 3 : 1.5, dash: isTargeted ? [] : [8, 6])
                )
            }
            .padding(12)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
        }
    }
}

struct EmptyStateView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        ContentUnavailableView {
            Label("Drop documents here", systemImage: "doc.viewfinder")
        } description: {
            Text("PDF and image files are analyzed by the model and renamed in place.\nNothing is renamed until you click Rename.")
        } actions: {
            Button("Add Files or Folders…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
            if model.settings.watchingEnabled, !model.access.watchedFolders.isEmpty {
                Text("Watching \(model.access.watchedFolders.count) folder(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ReviewTable: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        @Bindable var model = model
        Table(model.items, selection: $model.selection) {
            TableColumn("") { item in
                Toggle("Rename", isOn: model.checkedBinding(item.id))
                    .labelsHidden()
                    .disabled(!item.canRename)
            }
            .width(24)

            TableColumn("Preview") { item in
                ThumbnailCell(item: item)
            }
            .width(52)

            TableColumn("Source name") { item in
                Text(item.originalName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Target name") { item in
                TargetNameCell(item: item)
            }
            .width(min: 220, ideal: 420)

            TableColumn("Status") { item in
                StatusBadge(status: item.status)
            }
            .width(min: 80, ideal: 90, max: 110)
        }
        .contextMenu(forSelectionType: DocumentItem.ID.self) { ids in
            Button("Preview") { model.previewItemID = ids.first }
                .disabled(ids.count != 1)
            Button("Re-analyze") { model.reanalyze(ids: ids) }
            Button("Reveal in Finder") { model.revealInFinder(ids: ids) }
            Divider()
            Button("Remove from List") { model.remove(ids: ids) }
        } primaryAction: { ids in
            model.previewItemID = ids.first
        }
        .onKeyPress(.space) {
            model.previewSelection()
            return model.previewItemID == nil ? .ignored : .handled
        }
        .onDeleteCommand {
            model.remove(ids: model.selection)
        }
    }
}

/// Editable target name; the extension is shown after the field and cannot be changed here.
struct TargetNameCell: View {
    private var model: AppModel { AppModel.shared }
    let item: DocumentItem

    var body: some View {
        if item.canRename {
            HStack(spacing: 2) {
                TextField("Target name", text: model.fullNameBinding(item.id))
                    .textFieldStyle(.plain)
                Text(".\(item.fileExtension)")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(item.status == .renamed ? item.originalName : (item.status.detail ?? model.proposedName(for: item)))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
    }
}

struct ThumbnailCell: View {
    private var model: AppModel { AppModel.shared }
    let item: DocumentItem

    var body: some View {
        Group {
            if let image = model.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: item.fileExtension == "pdf" ? "doc.richtext" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = [item.id]
            model.previewItemID = item.id
        }
        .help("Click or press Space to preview")
    }
}

struct StatusBadge: View {
    let status: DocumentItem.Status

    var body: some View {
        HStack(spacing: 4) {
            if case .analyzing = status {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(color)
            }
            Text(status.label)
                .font(.callout)
        }
        .help(status.detail ?? status.label)
    }

    private var symbol: String {
        switch status {
        case .pending: "circle.dotted"
        case .analyzing: "hourglass"
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .renamed: "checkmark.seal.fill"
        case .skipped: "minus.circle"
        }
    }

    private var color: Color {
        switch status {
        case .pending, .analyzing: .secondary
        case .ready: .green
        case .warning: .orange
        case .error: .red
        case .renamed: .blue
        case .skipped: .secondary
        }
    }
}
