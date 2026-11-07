import Foundation

/// Unified diff → files → hunks → lines with old/new line numbers.
struct DiffLine: Hashable, Identifiable {
    enum Kind { case context, added, removed, hunk, meta }
    let id: Int
    let kind: Kind
    let text: String
    let oldNo: Int?
    let newNo: Int?
}

struct DiffFile: Hashable, Identifiable {
    var id: String { path + "#\(index)" }
    let index: Int
    let path: String
    var lines: [DiffLine]
    var added: Int
    var removed: Int
}

enum DiffParser {
    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var oldNo = 0, newNo = 0, lineId = 0
        func flush() { if let c = current { files.append(c) }; current = nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flush()
                let path = line.components(separatedBy: " b/").last ?? line
                current = DiffFile(index: files.count, path: path, lines: [], added: 0, removed: 0)
                continue
            }
            if line.hasPrefix("--- ") && current == nil { current = DiffFile(index: files.count, path: "", lines: [], added: 0, removed: 0) }
            if line.hasPrefix("+++ ") {
                let p = String(line.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored)
                if current?.path.isEmpty ?? true { current?.path = p }
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") || line.hasPrefix("rename ") || line.hasPrefix("old mode") || line.hasPrefix("new mode") { continue }
            guard current != nil else { continue }
            lineId += 1
            if line.hasPrefix("@@") {
                // @@ -a,b +c,d @@ heading
                let nums = line.split(separator: " ")
                if nums.count >= 3 {
                    oldNo = Int(nums[1].dropFirst().split(separator: ",").first ?? "0") ?? 0
                    newNo = Int(nums[2].dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                current!.lines.append(DiffLine(id: lineId, kind: .hunk, text: line, oldNo: nil, newNo: nil))
            } else if line.hasPrefix("+") {
                current!.lines.append(DiffLine(id: lineId, kind: .added, text: String(line.dropFirst()), oldNo: nil, newNo: newNo)); newNo += 1; current!.added += 1
            } else if line.hasPrefix("-") {
                current!.lines.append(DiffLine(id: lineId, kind: .removed, text: String(line.dropFirst()), oldNo: oldNo, newNo: nil)); oldNo += 1; current!.removed += 1
            } else if line.hasPrefix("\\") {
                current!.lines.append(DiffLine(id: lineId, kind: .meta, text: line, oldNo: nil, newNo: nil))
            } else if line.hasPrefix(" ") || (line.isEmpty && !(current!.lines.isEmpty)) {
                current!.lines.append(DiffLine(id: lineId, kind: .context, text: line.isEmpty ? "" : String(line.dropFirst()), oldNo: oldNo, newNo: newNo)); oldNo += 1; newNo += 1
            }
        }
        flush()
        // Trailing blank context lines produced by the final newline.
        return files.map { f in var f = f; while let l = f.lines.last, l.kind == .context, l.text.isEmpty, l.oldNo != nil { f.lines.removeLast() }; return f }
    }

    /// A mini unified diff for a Claude Code Edit (old_string → new_string),
    /// so the change is visible before the file watcher's revision lands.
    static func fromEdit(old: String, new: String, path: String) -> String {
        let o = old.components(separatedBy: "\n"), n = new.components(separatedBy: "\n")
        var out = ["--- a/\(path)", "+++ b/\(path)", "@@ -1,\(o.count) +1,\(n.count) @@"]
        out += o.map { "-" + $0 }
        out += n.map { "+" + $0 }
        return out.joined(separator: "\n")
    }
}
