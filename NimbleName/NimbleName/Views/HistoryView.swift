import SwiftUI

struct HistoryView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        Group {
            if model.history.records.isEmpty {
                ContentUnavailableView("No renames yet", systemImage: "clock")
            } else {
                List(model.history.records.reversed()) { record in
                    HistoryRow(record: record)
                }
            }
        }
        .toolbar {
            Button("Clear History", systemImage: "trash") { model.history.clear() }
                .disabled(model.history.records.isEmpty)
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}

private struct HistoryRow: View {
    private var model: AppModel { AppModel.shared }
    let record: RenameRecord

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.toURL.lastPathComponent)
                    .strikethrough(record.reverted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("was: \(record.fromURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(record.folderName) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if record.reverted {
                Text("Reverted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Revert") { model.revert([record]) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
