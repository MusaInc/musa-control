import UIKit
import SwiftUI

/// Lightweight regex highlighter covering the languages in the Musa projects
/// (Swift, JS/TS, Python, GDScript, shaders, shell, JSON, YAML, HTML/CSS,
/// Kotlin, Markdown). Line-oriented so huge files stay responsive.
enum SyntaxHighlighter {
    struct Lang {
        let keywords: Set<String>
        let lineComment: String?
        let blockComment: (String, String)?
        let hashComment: Bool
    }

    // Light and dark variants; the dark set is the original palette.
    static let palette: [String: UIColor] = [
        "kw": Theme.uiDyn((0.522, 0.243, 0.792), (0.776, 0.580, 0.996)),
        "str": Theme.uiDyn((0.169, 0.494, 0.200), (0.596, 0.851, 0.592)),
        "num": Theme.uiDyn((0.706, 0.369, 0.039), (0.980, 0.733, 0.459)),
        "com": Theme.uiDyn((0.478, 0.486, 0.514), (0.494, 0.518, 0.565)),
        "type": Theme.uiDyn((0.090, 0.396, 0.710), (0.459, 0.765, 0.996)),
        "fn": Theme.uiDyn((0.580, 0.384, 0.0), (0.988, 0.835, 0.561)),
        "tag": Theme.uiDyn((0.725, 0.196, 0.196), (0.973, 0.541, 0.541)),
        "plain": Theme.uiDyn((0.114, 0.114, 0.122), (0.886, 0.894, 0.910)),
    ]

    static let common = Set<String>(["if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default", "in", "true", "false", "null", "nil", "None", "True", "False", "do", "try", "catch", "throw", "throws", "import", "from", "as", "class", "struct", "enum", "func", "function", "def", "let", "var", "const", "static", "public", "private", "protected", "extends", "super", "self", "this", "new", "async", "await", "export", "yield", "and", "or", "not", "is", "with", "pass", "lambda", "elif", "guard", "where", "protocol", "extension", "interface", "type", "val", "fun", "object", "override", "signal", "extends", "onready", "match", "await", "typeof", "instanceof", "void", "uniform", "varying", "shader_type", "render_mode", "in", "out", "inout", "package", "init", "deinit", "some", "any", "mutating", "final", "lazy", "weak", "of", "delete", "finally", "raise", "global", "nonlocal", "assert", "fn", "impl", "mod", "use", "pub", "mut", "then", "fi", "done", "esac", "local", "echo", "export"] as [String])

    static func lang(for path: String) -> Lang {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "py", "gd", "sh", "bash", "zsh", "yml", "yaml", "toml", "cfg", "conf", "rb", "tscn", "tres", "godot", "gitignore", "env", "service", "ini", "dockerfile", "makefile":
            return Lang(keywords: common, lineComment: nil, blockComment: nil, hashComment: true)
        case "json", "md", "txt", "csv":
            return Lang(keywords: ["true", "false", "null"], lineComment: nil, blockComment: nil, hashComment: false)
        case "html", "xml", "svg", "plist", "vue", "svelte":
            return Lang(keywords: [], lineComment: nil, blockComment: ("<!--", "-->"), hashComment: false)
        case "css", "scss":
            return Lang(keywords: ["important", "media", "keyframes", "root"], lineComment: nil, blockComment: ("/*", "*/"), hashComment: false)
        default:
            return Lang(keywords: common, lineComment: "//", blockComment: ("/*", "*/"), hashComment: false)
        }
    }

    private static let stringRe = try! NSRegularExpression(pattern: #"("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#)
    private static let numberRe = try! NSRegularExpression(pattern: #"\b(0x[0-9a-fA-F]+|\d+(\.\d+)?([eE][+-]?\d+)?)\b"#)
    private static let wordRe = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
    private static let callRe = try! NSRegularExpression(pattern: #"\b([a-z_][A-Za-z0-9_]*)(?=\()"#)
    private static let tagRe = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*"#)

    static func highlight(_ text: String, path: String, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: palette["plain"]!])
        guard text.utf16.count < 400_000 else { return out }
        let l = lang(for: path)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var protected = IndexSet()
        func paint(_ r: NSRange, _ key: String) { out.addAttribute(.foregroundColor, value: palette[key]!, range: r) }
        func isProtected(_ r: NSRange) -> Bool { protected.contains(r.location) }

        let isMarkup = l.blockComment?.0 == "<!--"
        if isMarkup { tagRe.enumerateMatches(in: text, range: full) { m, _, _ in if let r = m?.range { paint(r, "tag") } } }
        callRe.enumerateMatches(in: text, range: full) { m, _, _ in if let r = m?.range(at: 1) { paint(r, "fn") } }
        wordRe.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let r = m?.range else { return }
            let w = ns.substring(with: r)
            if l.keywords.contains(w) { paint(r, "kw") }
            else if let f = w.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f), w.count > 1 { paint(r, "type") }
        }
        numberRe.enumerateMatches(in: text, range: full) { m, _, _ in if let r = m?.range { paint(r, "num") } }
        stringRe.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let r = m?.range, r.length < 4000 else { return }
            paint(r, "str"); protected.insert(integersIn: r.location..<(r.location + r.length))
        }
        // Comments last (they win over everything except strings that start earlier).
        var lineStart = 0
        for line in text.components(separatedBy: "\n") {
            let len = (line as NSString).length
            let marker: String? = l.hashComment ? "#" : l.lineComment
            if let marker {
                var search = NSRange(location: lineStart, length: len)
                while true {
                    let found = ns.range(of: marker, options: [], range: search)
                    if found.location == NSNotFound { break }
                    if !isProtected(found) { paint(NSRange(location: found.location, length: lineStart + len - found.location), "com"); break }
                    let next = found.location + found.length
                    search = NSRange(location: next, length: lineStart + len - next)
                    if search.length <= 0 { break }
                }
            }
            lineStart += len + 1
        }
        if let (open, close) = l.blockComment {
            var loc = 0
            while loc < ns.length {
                let o = ns.range(of: open, options: [], range: NSRange(location: loc, length: ns.length - loc))
                if o.location == NSNotFound { break }
                if isProtected(o) { loc = o.location + o.length; continue }
                let c = ns.range(of: close, options: [], range: NSRange(location: o.location + o.length, length: ns.length - o.location - o.length))
                let end = c.location == NSNotFound ? ns.length : c.location + c.length
                paint(NSRange(location: o.location, length: end - o.location), "com")
                loc = end
            }
        }
        return out
    }

    /// Syntax colour of the last character of a line (for the typing bloom).
    static func lastColor(_ line: String, path: String) -> Color {
        let ns = highlight(line, path: path, font: UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
        guard ns.length > 0, let c = ns.attribute(.foregroundColor, at: ns.length - 1, effectiveRange: nil) as? UIColor else { return Theme.accent }
        return Color(uiColor: c)
    }

    static func attributed(_ line: String, path: String) -> AttributedString {
        let ns = highlight(line, path: path, font: UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
        return (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(line)
    }
}
