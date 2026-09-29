import Foundation

/// One rename, persisted for undo / history.
nonisolated struct RenameRecord: Codable, Identifiable, Sendable, Hashable {
    var id = UUID()
    var batchID: UUID
    var date = Date()
    var fromPath: String
    var toPath: String
    var reverted = false

    var fromURL: URL { URL(fileURLWithPath: fromPath) }
    var toURL: URL { URL(fileURLWithPath: toPath) }
    var folderName: String { toURL.deletingLastPathComponent().lastPathComponent }
}
