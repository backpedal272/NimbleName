import Foundation

/// One row of the review table.
nonisolated struct DocumentItem: Identifiable, Sendable, Hashable {
    nonisolated enum Status: Sendable, Hashable {
        case pending
        case analyzing
        case ready
        case warning(String)
        case error(String)
        case renamed
        case skipped(String)

        var label: String {
            switch self {
            case .pending: "Pending"
            case .analyzing: "Analyzing"
            case .ready: "Ready"
            case .warning: "Check"
            case .error: "Error"
            case .renamed: "Renamed"
            case .skipped: "Skipped"
            }
        }

        var detail: String? {
            switch self {
            case .warning(let s), .error(let s), .skipped(let s): s
            default: nil
            }
        }
    }

    let id: UUID
    var url: URL
    var status: Status = .pending
    var fields = ExtractedFields()
    /// Full-name override typed in the preview when it does not parse back into fields.
    var customName: String?
    /// Rendered first page / downscaled image as JPEG. Reused for thumbnail, preview and the API call.
    var imageData: Data?
    var isChecked = false
    /// True when the file arrived through a watched folder (drives the notification).
    var fromWatcher = false

    init(url: URL, fromWatcher: Bool = false) {
        self.id = UUID()
        self.url = url
        self.fromWatcher = fromWatcher
    }

    var originalName: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }
    var folder: URL { url.deletingLastPathComponent() }

    var canRename: Bool {
        switch status {
        case .ready, .warning: true
        default: false
        }
    }

    var isAwaitingReview: Bool { canRename }
}
