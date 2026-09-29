import Foundation
import Observation

/// Persistent list of renames, newest last. Backs the Undo command and the History window.
@Observable
final class HistoryStore {
    static let maxRecords = 1000

    private(set) var records: [RenameRecord] = []
    @ObservationIgnored private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("Nimble Name", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
        load()
    }

    /// All records of the most recent batch that still has un-reverted renames.
    var lastUndoableBatch: [RenameRecord] {
        guard let batchID = records.last(where: { !$0.reverted })?.batchID else { return [] }
        return records.filter { $0.batchID == batchID && !$0.reverted }
    }

    var canUndo: Bool { !lastUndoableBatch.isEmpty }

    func append(_ newRecords: [RenameRecord]) {
        records.append(contentsOf: newRecords)
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
        save()
    }

    func markReverted(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].reverted = true
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([RenameRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
