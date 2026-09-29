import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import os

private let log = Logger(subsystem: "pm.ad0.NimbleName", category: "intake")

/// Central state: the review table, analysis pipeline, renaming, undo and folder watching.
@Observable
final class AppModel {
    /// Single instance used by every view. Avoids SwiftUI environment lookups, which
    /// crashed in separately hosted views (toolbar, menu bar) on macOS 27.
    static let shared = AppModel()

    var settings = AppSettings()
    var access = FolderAccess()
    var history = HistoryStore()
    let watcher = FolderWatcher()

    var items: [DocumentItem] = []
    var selection = Set<DocumentItem.ID>()
    var previewItemID: DocumentItem.ID?
    var lastError: String?

    private(set) var activeAnalyses = 0
    var isAnalyzing: Bool { activeAnalyses > 0 }

    @ObservationIgnored private var recentlyRenamed = Set<String>()
    @ObservationIgnored private let imageCache = NSCache<NSUUID, NSImage>()

    init() {
        log.notice("AppModel started, bundle \(Bundle.main.bundlePath, privacy: .public)")
        watcher.onChange = { [weak self] url in self?.scanWatchedFolder(url) }
        observeWatchSetting()
        syncWatcher()
        if settings.watchingEnabled {
            for folder in access.watchedFolders { scanWatchedFolder(folder) }
        }
    }

    // MARK: - Derived counts

    var readyItems: [DocumentItem] { items.filter(\.canRename) }
    var readyCount: Int { readyItems.count }
    var checkedCount: Int { items.filter { $0.isChecked && $0.canRename }.count }
    var pendingCount: Int { items.filter { $0.status == .pending }.count }
    var renamedCount: Int {
        items.filter {
            if case .skipped = $0.status { return true }
            return $0.status == .renamed
        }.count
    }

    // MARK: - Item access

    func item(_ id: DocumentItem.ID) -> DocumentItem? {
        items.first { $0.id == id }
    }

    private func update(_ id: DocumentItem.ID, _ body: (inout DocumentItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    func setField(_ id: DocumentItem.ID, _ keyPath: WritableKeyPath<ExtractedFields, String>, _ value: String) {
        update(id) {
            $0.fields[keyPath: keyPath] = value
            $0.customName = nil
        }
    }

    func fieldBinding(_ id: DocumentItem.ID, _ keyPath: WritableKeyPath<ExtractedFields, String>) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.item(id)?.fields[keyPath: keyPath] ?? "" },
            set: { [weak self] in self?.setField(id, keyPath, $0) }
        )
    }

    func checkedBinding(_ id: DocumentItem.ID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.item(id)?.isChecked ?? false },
            set: { [weak self] value in self?.update(id) { $0.isChecked = value } }
        )
    }

    /// Filename without extension, as the user will see it.
    func proposedBaseName(for item: DocumentItem) -> String {
        if let custom = item.customName { return custom }
        return FilenameComposer.compose(template: settings.template, fields: item.fields, maxLength: settings.maxFilenameLength)
    }

    /// Final filename with extension, sanitized.
    func proposedName(for item: DocumentItem) -> String {
        let base = FilenameComposer.sanitize(proposedBaseName(for: item), maxLength: settings.maxFilenameLength)
        return base.isEmpty ? item.originalName : base + "." + item.fileExtension
    }

    func setFullName(_ id: DocumentItem.ID, _ name: String) {
        guard let item = item(id) else { return }
        var base = name
        let suffix = "." + item.fileExtension
        if base.lowercased().hasSuffix(suffix) { base = String(base.dropLast(suffix.count)) }

        if let parsed = FilenameComposer.parse(base, template: settings.template),
           FilenameComposer.compose(template: settings.template, fields: parsed, maxLength: settings.maxFilenameLength) == base {
            update(id) { $0.fields = parsed; $0.customName = nil }
        } else {
            update(id) { $0.customName = base }
        }
    }

    func fullNameBinding(_ id: DocumentItem.ID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self, let item = self.item(id) else { return "" }
                return self.proposedBaseName(for: item)
            },
            set: { [weak self] in self?.setFullName(id, $0) }
        )
    }

    func image(for item: DocumentItem) -> NSImage? {
        if let cached = imageCache.object(forKey: item.id as NSUUID) { return cached }
        guard let data = item.imageData, let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: item.id as NSUUID)
        return image
    }

    func remove(ids: Set<DocumentItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let preview = previewItemID, ids.contains(preview) { previewItemID = nil }
    }

    func clearRenamed() {
        remove(ids: Set(items.filter {
            if case .skipped = $0.status { return true }
            return $0.status == .renamed
        }.map(\.id)))
    }

    func revealInFinder(ids: Set<DocumentItem.ID>) {
        let urls = items.filter { ids.contains($0.id) }.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Preview navigation

    func previewStep(_ delta: Int) {
        guard let current = previewItemID,
              let index = items.firstIndex(where: { $0.id == current }) else { return }
        let next = index + delta
        guard items.indices.contains(next) else { return }
        previewItemID = items[next].id
        selection = [items[next].id]
    }

    func previewSelection() {
        guard let first = items.first(where: { selection.contains($0.id) }) else { return }
        previewItemID = first.id
    }

    // MARK: - Intake

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose documents or folders to rename"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        log.notice("open panel returned \(panel.urls.count) url(s)")
        addURLs(panel.urls)
    }

    func addURLs(_ urls: [URL], fromWatcher: Bool = false) {
        log.notice("addURLs: \(urls.count) url(s), fromWatcher=\(fromWatcher)")
        var added: [DocumentItem.ID] = []
        for url in urls {
            // Dropped and panel-selected URLs may be security-scoped; starting access is harmless otherwise.
            _ = url.startAccessingSecurityScopedResource()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                log.error("addURLs: cannot access \(url.path, privacy: .public)")
                if !fromWatcher { addSkippedRow(url, reason: "Cannot access this file (sandbox denied it)") }
                continue
            }
            if isDirectory.boolValue {
                access.grant(url)
                let files = collectFiles(in: url)
                log.info("addURLs: folder \(url.lastPathComponent, privacy: .public) contains \(files.count) file(s)")
                for file in files {
                    if let id = addFile(file, fromWatcher: fromWatcher, showSkipped: false) { added.append(id) }
                }
                if files.isEmpty, !fromWatcher { addSkippedRow(url, reason: "Folder contains no files") }
            } else if let id = addFile(url, fromWatcher: fromWatcher, showSkipped: !fromWatcher) {
                added.append(id)
            }
        }
        log.notice("addURLs: \(added.count) file(s) queued for analysis")
        analyze(ids: added)
    }

    /// Adds a row that explains why a file was not queued. Only for manual intake, never for the watcher.
    private func addSkippedRow(_ url: URL, reason: String) {
        guard !items.contains(where: { $0.url == url.standardizedFileURL }) else { return }
        var item = DocumentItem(url: url.standardizedFileURL)
        item.status = .skipped(reason)
        items.append(item)
    }

    private func addFile(_ url: URL, fromWatcher: Bool, showSkipped: Bool) -> DocumentItem.ID? {
        let url = url.standardizedFileURL
        let ext = url.pathExtension.lowercased()
        guard AppSettings.supportedExtensions.contains(ext) else {
            log.info("skip (type .\(ext, privacy: .public)): \(url.lastPathComponent, privacy: .public)")
            if showSkipped { addSkippedRow(url, reason: "Unsupported file type .\(ext)") }
            return nil
        }
        if let existing = items.first(where: { $0.url == url }) {
            log.info("skip (already listed): \(url.lastPathComponent, privacy: .public)")
            if case .skipped = existing.status, showSkipped {
                // The user is retrying a skipped file: analyze it this time.
                update(existing.id) { $0.status = .pending }
                return existing.id
            }
            return nil
        }
        guard !recentlyRenamed.contains(url.path) else {
            log.info("skip (renamed this session): \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        // Manually added files are always analyzed; the "already named" rule only applies to watched folders.
        if fromWatcher, settings.skipAlreadyNamed,
           FilenameComposer.matches(url.deletingPathExtension().lastPathComponent, template: settings.template) {
            log.info("skip (already named): \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        let item = DocumentItem(url: url, fromWatcher: fromWatcher)
        items.append(item)
        return item.id
    }

    private func collectFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func topLevelFiles(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    // MARK: - Analysis

    func analyzePending() {
        analyze(ids: items.filter { $0.status == .pending }.map(\.id))
    }

    /// Also the way to force analysis of a row that was skipped (already named, unsupported type).
    func reanalyze(ids: Set<DocumentItem.ID>) {
        for id in ids { update(id) { $0.status = .pending; $0.isChecked = false } }
        analyze(ids: Array(ids))
    }

    func analyze(ids: [DocumentItem.ID]) {
        guard !ids.isEmpty else { return }
        Task { await runAnalysis(ids) }
    }

    private func runAnalysis(_ ids: [DocumentItem.ID]) async {
        activeAnalyses += 1
        defer { activeAnalyses -= 1 }

        let parallel = max(1, min(4, settings.parallelRequests))
        await withTaskGroup(of: Void.self) { group in
            var iterator = ids.makeIterator()
            var running = 0
            while running < parallel, let id = iterator.next() {
                group.addTask { await self.analyzeOne(id) }
                running += 1
            }
            while await group.next() != nil {
                if let id = iterator.next() {
                    group.addTask { await self.analyzeOne(id) }
                }
            }
        }

        let idSet = Set(ids)
        let readyFromWatcher = items.filter { idSet.contains($0.id) && $0.fromWatcher && $0.canRename }.count
        if readyFromWatcher > 0, settings.notifyWhenReady {
            postNotification(count: readyFromWatcher)
        }
    }

    private func analyzeOne(_ id: DocumentItem.ID) async {
        guard let item = item(id) else { return }
        update(id) { $0.status = .analyzing }
        do {
            log.info("analyze: \(item.url.lastPathComponent, privacy: .public)")
            let jpeg = try await ImageRenderer.renderJPEG(from: item.url)
            imageCache.removeObject(forKey: id as NSUUID)
            update(id) { $0.imageData = jpeg }

            let client = LLMClient(config: settings.llmConfiguration)
            var fields = try await client.extractFields(imageJPEG: jpeg)
            if fields.date.isEmpty {
                fields.date = Self.creationDateString(for: item.url)
            }
            let filled = [fields.date, fields.vendor, fields.description, fields.currency, fields.amount].filter { !$0.isEmpty }.count
            log.info("analyze done for \(item.url.lastPathComponent, privacy: .public): \(filled, privacy: .public)/5 fields, description \(fields.description)")
            update(id) {
                $0.fields = fields
                $0.customName = nil
                $0.status = fields.isIncomplete ? .warning("The model could not describe this document") : .ready
                $0.isChecked = !fields.isIncomplete
            }
        } catch {
            log.error("analyze failed for \(item.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            update(id) {
                $0.status = .error(error.localizedDescription)
                $0.isChecked = false
            }
        }
    }

    // MARK: - Renaming

    func renameChecked() {
        rename(ids: items.filter { $0.isChecked && $0.canRename }.map(\.id))
    }

    func rename(ids: [DocumentItem.ID]) {
        let batchID = UUID()
        var records: [RenameRecord] = []

        for id in ids {
            guard let item = item(id), item.canRename else { continue }
            let folder = item.folder

            if !access.hasAccess(to: folder) {
                access.requestAccess(
                    for: folder,
                    message: "Nimble Name needs permission to rename files in “\(folder.lastPathComponent)”. Click Grant Access to allow it."
                )
                guard access.hasAccess(to: folder) else {
                    update(id) { $0.status = .error("No permission to rename in this folder"); $0.isChecked = false }
                    continue
                }
            }

            let newName = proposedName(for: item)
            if newName == item.originalName {
                update(id) { $0.status = .renamed; $0.isChecked = false }
                continue
            }

            let destination = uniqueDestination(in: folder, name: newName)
            do {
                try Self.move(item.url, to: destination)
                recentlyRenamed.insert(destination.path)
                records.append(RenameRecord(batchID: batchID, fromPath: item.url.path, toPath: destination.path))
                update(id) { $0.url = destination; $0.status = .renamed; $0.isChecked = false }
            } catch {
                update(id) { $0.status = .error("Rename failed: \(error.localizedDescription)"); $0.isChecked = false }
            }
        }

        if !records.isEmpty { history.append(records) }
    }

    private func uniqueDestination(in folder: URL, name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private static func move(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: [],
            error: &coordinationError
        ) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to) } catch { moveError = error }
        }
        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
    }

    // MARK: - Undo / history

    func undoLastBatch() {
        revert(history.lastUndoableBatch.reversed())
    }

    func revert(_ records: [RenameRecord]) {
        for record in records where !record.reverted {
            let folder = record.toURL.deletingLastPathComponent()
            if !access.hasAccess(to: folder) {
                access.requestAccess(
                    for: folder,
                    message: "Nimble Name needs permission to revert a rename in “\(folder.lastPathComponent)”."
                )
                guard access.hasAccess(to: folder) else {
                    lastError = "No permission to revert “\(record.toURL.lastPathComponent)”."
                    continue
                }
            }
            guard FileManager.default.fileExists(atPath: record.toPath) else {
                lastError = "“\(record.toURL.lastPathComponent)” no longer exists."
                continue
            }
            guard !FileManager.default.fileExists(atPath: record.fromPath) else {
                lastError = "A file named “\(record.fromURL.lastPathComponent)” already exists."
                continue
            }
            do {
                try Self.move(record.toURL, to: record.fromURL)
                history.markReverted(record.id)
                recentlyRenamed.remove(record.toPath)
                recentlyRenamed.insert(record.fromPath)
                if let index = items.firstIndex(where: { $0.url.path == record.toPath }) {
                    items[index].url = record.fromURL
                    items[index].status = items[index].imageData == nil ? .pending : .ready
                }
            } catch {
                lastError = "Revert failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Watching

    private func observeWatchSetting() {
        withObservationTracking {
            _ = settings.watchingEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncWatcher()
                self?.observeWatchSetting()
            }
        }
    }

    func syncWatcher() {
        if settings.watchingEnabled {
            watcher.watch(access.watchedFolders)
            for folder in access.watchedFolders { scanWatchedFolder(folder) }
        } else {
            watcher.stopAll()
        }
    }

    func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to watch for new documents"
        panel.prompt = "Watch"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { access.grant(url, watched: true) }
        syncWatcher()
    }

    func removeWatchedFolder(_ url: URL) {
        access.setWatched(url, false)
        syncWatcher()
    }

    func scanWatchedFolder(_ folder: URL) {
        guard settings.watchingEnabled else { return }
        let candidates = topLevelFiles(in: folder).map(\.standardizedFileURL).filter { url in
            guard AppSettings.supportedExtensions.contains(url.pathExtension.lowercased()) else { return false }
            guard !items.contains(where: { $0.url == url }) else { return false }
            guard !recentlyRenamed.contains(url.path) else { return false }
            if settings.skipAlreadyNamed,
               FilenameComposer.matches(url.deletingPathExtension().lastPathComponent, template: settings.template) {
                return false
            }
            return true
        }
        guard !candidates.isEmpty else { return }

        Task {
            // Only pick up files whose size is stable, so half-written scans are not analyzed.
            let before = candidates.map(Self.fileSize)
            try? await Task.sleep(for: .seconds(2))
            let after = candidates.map(Self.fileSize)
            var stable: [URL] = []
            var unstable = false
            for (index, url) in candidates.enumerated() {
                if before[index] == after[index], after[index] > 0 { stable.append(url) } else { unstable = true }
            }
            addURLs(stable, fromWatcher: true)
            if unstable {
                try? await Task.sleep(for: .seconds(5))
                scanWatchedFolder(folder)
            }
        }
    }

    /// File creation date (falls back to modification date, then today) as YYYY-MM-DD.
    private static func creationDateString(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let date = values?.creationDate ?? values?.contentModificationDate ?? Date()
        return date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
    }

    private func postNotification(count: Int) {
        let body = count == 1 ? "1 file ready to rename" : "\(count) files ready to rename"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Nimble Name"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
