import SwiftUI

/// Renders unified diffs (git, revisions, agent edits) with line numbers and
/// added/removed highlighting. Lazy, so large diffs scroll smoothly.
struct DiffView: View {
    let diff: String
    var emptyText = "No changes"
    @State private var files: [DiffFile] = []
    @State private var collapsed: Set<String> = []

    var body: some View {
        Group {
            if files.isEmpty {
                EmptyNote(icon: "equal.circle", text: emptyText)
            } else {
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(files) { f in
                            SwiftUI.Section {
                                if !collapsed.contains(f.id) {
                                    ForEach(f.lines) { line in DiffLineRow(line: line, path: f.path) }
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Image(systemName: collapsed.contains(f.id) ? "chevron.right" : "chevron.down").font(.system(size: 11.5, weight: .semibold))
                                    Text(f.path).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("+\(f.added)").font(Theme.monoSmall).foregroundStyle(Theme.green)
                                    Text("−\(f.removed)").font(Theme.monoSmall).foregroundStyle(Theme.red)
                                }
                                .foregroundStyle(Theme.textDim)
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Theme.raised)
                                .contentShape(Rectangle())
                                .onTapGesture { if collapsed.contains(f.id) { collapsed.remove(f.id) } else { collapsed.insert(f.id) } }
                            }
                        }
                    }
                }
            }
        }
        .task(id: diff) { files = DiffParser.parse(diff) }
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let path: String
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNo.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(line.newNo.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(marker).frame(width: 18).foregroundStyle(markerColor)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.mono)
        .foregroundStyle(Theme.textFaint)
        .padding(.vertical, 0.5)
        .background(bg)
        .textSelection(.enabled)
    }
    @ViewBuilder var content: some View {
        if line.kind == .hunk || line.kind == .meta {
            Text(line.text).foregroundStyle(Theme.blue.opacity(0.8)).lineLimit(1)
        } else {
            Text(SyntaxHighlighter.attributed(line.text, path: path)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
    }
    var marker: String { switch line.kind { case .added: return "+"; case .removed: return "−"; default: return "" } }
    var markerColor: Color { line.kind == .added ? Theme.green : Theme.red }
    var bg: Color {
        switch line.kind { case .added: return Theme.addedBg; case .removed: return Theme.removedBg; case .hunk: return Theme.blue.opacity(0.06); default: return .clear }
    }
}
