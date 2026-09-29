import Foundation
import Observation

/// Watches folders for changes with a debounced callback (top level only).
@Observable
final class FolderWatcher {
    var onChange: (@MainActor (URL) -> Void)?

    @ObservationIgnored private var sources: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var debounceTasks: [String: Task<Void, Never>] = [:]

    private(set) var watchedPaths: [String] = []

    var isActive: Bool { !sources.isEmpty }

    func watch(_ folders: [URL]) {
        var wanted: [String: URL] = [:]
        for folder in folders { wanted[folder.path] = folder }

        for (path, source) in sources where wanted[path] == nil {
            source.cancel()
            sources[path] = nil
            debounceTasks[path]?.cancel()
            debounceTasks[path] = nil
        }
        for (path, url) in wanted where sources[path] == nil {
            start(url)
        }
        watchedPaths = sources.keys.sorted()
    }

    func stopAll() {
        watch([])
    }

    private func start(_ url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleScan(url)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        sources[url.path] = source
    }

    private func scheduleScan(_ url: URL) {
        debounceTasks[url.path]?.cancel()
        debounceTasks[url.path] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.onChange?(url)
        }
    }
}
