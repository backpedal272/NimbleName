import AppKit
import Foundation
import Observation

/// Security-scoped folder grants (sandbox). A grant may also be flagged as a watched folder.
@Observable
final class FolderAccess {
    nonisolated struct Grant: Codable, Sendable {
        var bookmark: Data
        var isWatched: Bool
    }

    private struct Entry {
        var url: URL
        var isWatched: Bool
    }

    private static let defaultsKey = "folderGrants"

    private var entries: [Entry] = [] {
        didSet { save() }
    }

    var folders: [URL] { entries.map(\.url) }
    var watchedFolders: [URL] { entries.filter(\.isWatched).map(\.url) }

    init() {
        load()
    }

    func hasAccess(to folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return entries.contains { path == $0.url.path || path.hasPrefix($0.url.path + "/") }
    }

    func isWatched(_ folder: URL) -> Bool {
        entries.contains { $0.url.path == folder.standardizedFileURL.path && $0.isWatched }
    }

    func grant(_ folder: URL, watched: Bool = false) {
        let folder = folder.standardizedFileURL
        if let index = entries.firstIndex(where: { $0.url.path == folder.path }) {
            if watched, !entries[index].isWatched { entries[index].isWatched = true }
            return
        }
        _ = folder.startAccessingSecurityScopedResource()
        entries.append(Entry(url: folder, isWatched: watched))
    }

    func setWatched(_ folder: URL, _ watched: Bool) {
        guard let index = entries.firstIndex(where: { $0.url.path == folder.standardizedFileURL.path }) else { return }
        entries[index].isWatched = watched
    }

    func remove(_ folder: URL) {
        guard let index = entries.firstIndex(where: { $0.url.path == folder.standardizedFileURL.path }) else { return }
        entries[index].url.stopAccessingSecurityScopedResource()
        entries.remove(at: index)
    }

    /// Shows an open panel positioned on `folder` so the user can grant access to it.
    @discardableResult
    func requestAccess(for folder: URL, message: String, watched: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.message = message
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        grant(url, watched: watched)
        return url
    }

    // MARK: - Persistence

    private func save() {
        let grants = entries.compactMap { entry -> Grant? in
            guard let data = try? entry.url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }
            return Grant(bookmark: data, isWatched: entry.isWatched)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(grants), forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let grants = try? JSONDecoder().decode([Grant].self, from: data) else { return }
        var loaded: [Entry] = []
        for grant in grants {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: grant.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            loaded.append(Entry(url: url, isWatched: grant.isWatched))
        }
        entries = loaded
    }
}
