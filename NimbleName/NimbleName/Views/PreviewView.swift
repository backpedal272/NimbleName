import SwiftUI

/// Quick Look style preview: the rendered page on the left, editable name and fields on the right.
struct PreviewView: View {
    private var model: AppModel { AppModel.shared }
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case name, date, vendor, description, amount }

    @FocusState private var focusedField: Field?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private var item: DocumentItem? {
        model.previewItemID.flatMap { model.item($0) }
    }

    private var position: String {
        guard let id = model.previewItemID,
              let index = model.items.firstIndex(where: { $0.id == id }) else { return "" }
        return "\(index + 1) of \(model.items.count)"
    }

    var body: some View {
        HSplitView {
            imagePane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            editorPane
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
        }
        .frame(minWidth: 960, idealWidth: 1200, minHeight: 620, idealHeight: 780)
        .onKeyPress(.space) { handleNavigationKey { dismiss() } }
        .onKeyPress(.leftArrow) { handleNavigationKey { model.previewStep(-1) } }
        .onKeyPress(.rightArrow) { handleNavigationKey { model.previewStep(1) } }
        .onKeyPress(.upArrow) { handleNavigationKey { model.previewStep(-1) } }
        .onKeyPress(.downArrow) { handleNavigationKey { model.previewStep(1) } }
    }

    private func handleNavigationKey(_ action: () -> Void) -> KeyPress.Result {
        guard focusedField == nil else { return .ignored }
        action()
        return .handled
    }

    // MARK: - Image

    private var imagePane: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let item, let image = model.image(for: item) {
                        let fit = min(
                            geometry.size.width / max(image.size.width, 1),
                            geometry.size.height / max(image.size.height, 1)
                        )
                        let scale = fit * zoom * pinch
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    } else {
                        ContentUnavailableView("No preview yet", systemImage: "photo", description: Text("The document has not been rendered."))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = clampZoom(zoom * value.magnification) }
                )
            }
            Divider()
            HStack {
                Text(item?.originalName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(position)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom = clampZoom(zoom / 1.25) }
                    .labelStyle(.iconOnly)
                Slider(value: $zoom, in: 1...4)
                    .frame(width: 100)
                Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom = clampZoom(zoom * 1.25) }
                    .labelStyle(.iconOnly)
                Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") { zoom = 1 }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(4, max(1, value))
    }

    // MARK: - Editor

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item {
                Form {
                    Section("Filename") {
                        TextField("Filename", text: model.fullNameBinding(item.id), axis: .vertical)
                            .lineLimit(2...5)
                            .focused($focusedField, equals: .name)
                            .disabled(!item.canRename)
                        Text("Extension: .\(item.fileExtension)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if item.customName != nil {
                            Label("Custom name; the fields below are ignored until you edit one.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Fields") {
                        TextField("Date", text: model.fieldBinding(item.id, \.date))
                            .focused($focusedField, equals: .date)
                        TextField("Vendor", text: model.fieldBinding(item.id, \.vendor))
                            .focused($focusedField, equals: .vendor)
                        TextField("Description", text: model.fieldBinding(item.id, \.description))
                            .focused($focusedField, equals: .description)
                        TextField("Amount", text: model.fieldBinding(item.id, \.amountText), prompt: Text("CHF 89.00"))
                            .focused($focusedField, equals: .amount)
                    }
                    .disabled(!item.canRename)
                    Section("Status") {
                        StatusBadge(status: item.status)
                        if let detail = item.status.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if case .error = item.status {
                            Button("Re-analyze") { model.reanalyze(ids: [item.id]) }
                        }
                    }
                }
                .formStyle(.grouped)

                Divider()
                HStack {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Skip") { skip() }
                    Button("Rename This File") { renameCurrent() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!item.canRename)
                }
                .padding()
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc")
            }
        }
    }

    private func skip() {
        if hasNext { model.previewStep(1) } else { dismiss() }
    }

    private func renameCurrent() {
        guard let item else { return }
        model.rename(ids: [item.id])
        if hasNext { model.previewStep(1) } else { dismiss() }
    }

    private var hasNext: Bool {
        guard let id = model.previewItemID,
              let index = model.items.firstIndex(where: { $0.id == id }) else { return false }
        return index + 1 < model.items.count
    }
}
