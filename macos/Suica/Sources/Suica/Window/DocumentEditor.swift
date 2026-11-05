import SuicaCore
import SwiftUI

/// The open file's own text in Edit mode. Give it `.id(path)`: a TextEditor can write its old buffer back after
/// the selection moved, so the binding only ever writes to the file it was made for.
struct DocumentEditor: View {
    let path: String
    let name: String
    let model: DocumentsModel

    var body: some View {
        TextEditor(text: Binding(
            get: { model.selectedPath == path ? model.draftText : model.draft(for: path) ?? "" },
            set: { if model.selectedPath == path { model.draftText = $0 } }))
        .font(.system(.body, design: .monospaced))
        .accessibilityLabel(name)
    }
}

/// A Draft whose file changed on disk (found by a disk check or a save): never merged, the Owner picks.
struct DiskChangedNotice: View {
    let overwrite: () -> Void
    let reload: () -> Void
    let keepEditing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.fileChangedOnDisk).font(.callout)
            HStack {
                Button(Copy.overwriteFile, action: overwrite)
                Button(Copy.reloadFile, action: reload)
                Button(Copy.keepEditing, action: keepEditing)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Beside a file name in the header and the list while the file has a Draft.
struct UnsavedDot: View {
    var body: some View {
        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.tint).accessibilityLabel(Copy.unsavedDot)
    }
}
