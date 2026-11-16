import SwiftUI
import UIKit

/// Read-only, syntax-highlighted source with line numbers. Optional line
/// marks highlight lines changed since the previous revision.
struct CodeView: View {
    let text: String
    let path: String
    var changed: Set<Int> = []
    var scrollTo: Int? = nil
    @State private var lines: [AttributedString] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(i + 1)").font(Theme.monoSmall).foregroundStyle(Theme.textFaint).frame(width: 44, alignment: .trailing).padding(.trailing, 10)
                            Text(l).font(Theme.mono).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 0.5)
                        .background(changed.contains(i + 1) ? Theme.addedBg : Color.clear)
                        .id(i + 1)
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 6)
            }
            .onChange(of: scrollTo) { _, n in if let n { withAnimation { proxy.scrollTo(n, anchor: .center) } } }
            .task(id: text) {
                let p = path
                let t = text
                let out = await Task.detached(priority: .userInitiated) { () -> [AttributedString] in
                    t.components(separatedBy: "\n").prefix(20000).map { SyntaxHighlighter.attributed($0, path: p) }
                }.value
                lines = out
                if let s = scrollTo { try? await Task.sleep(nanoseconds: 100_000_000); proxy.scrollTo(s, anchor: .center) }
            }
        }
    }
}

/// Editable source (TextKit). Highlighting reapplies when typing pauses;
/// undo/redo, Find (⌘F), hardware keyboard and trackpad selection come from
/// UITextView itself.
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    let path: String
    var fontSize: CGFloat = 13
    var jumpLine: Int? = nil
    var onSave: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EditorTextView {
        let v = EditorTextView()
        v.onSave = onSave
        v.backgroundColor = Theme.editorBg
        v.autocapitalizationType = .none
        v.autocorrectionType = .no
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.spellCheckingType = .no
        v.keyboardDismissMode = .interactive
        v.isFindInteractionEnabled = true
        v.alwaysBounceVertical = true
        v.textContainerInset = UIEdgeInsets(top: 10, left: 54, bottom: 40, right: 8)
        let bar = UIToolbar()
        bar.items = [
            UIBarButtonItem(title: "Undo", style: .plain, target: v, action: #selector(EditorTextView.undoEdit)),
            UIBarButtonItem(title: "Redo", style: .plain, target: v, action: #selector(EditorTextView.redoEdit)),
            UIBarButtonItem(title: "Find", style: .plain, target: v, action: #selector(EditorTextView.findText)),
            UIBarButtonItem(title: "Copy All", style: .plain, target: v, action: #selector(EditorTextView.copyAll)),
            UIBarButtonItem(title: "Save", style: .done, target: v, action: #selector(EditorTextView.save))
        ]
        bar.sizeToFit(); v.inputAccessoryView = bar
        v.delegate = context.coordinator
        v.tintColor = UIColor(Theme.accent)
        v.attributedText = SyntaxHighlighter.highlight(text, path: path, font: font)
        return v
    }

    var font: UIFont { UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }

    func updateUIView(_ v: EditorTextView, context: Context) {
        context.coordinator.parent = self
        v.onSave = onSave
        if v.text != text {
            let sel = v.selectedRange
            v.attributedText = SyntaxHighlighter.highlight(text, path: path, font: font)
            v.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
        }
        if let line = jumpLine, context.coordinator.lastJump != "\(path):\(line)" {
            context.coordinator.lastJump = "\(path):\(line)"
            let lines = text.components(separatedBy: "\n")
            let offset = lines.prefix(max(0, min(line - 1, lines.count - 1))).reduce(0) { $0 + ($1 as NSString).length + 1 }
            v.selectedRange = NSRange(location: min(offset, (text as NSString).length), length: 0)
            v.scrollRangeToVisible(v.selectedRange)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        var pending: DispatchWorkItem?
        var lastJump: String?
        init(_ p: CodeEditor) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            tv.setNeedsDisplay()
            pending?.cancel()
            let work = DispatchWorkItem { [weak tv, parent] in
                guard let tv else { return }
                let sel = tv.selectedRange
                let offset = tv.contentOffset
                tv.textStorage.beginEditing()
                let hl = SyntaxHighlighter.highlight(tv.text, path: parent.path, font: parent.font)
                hl.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: hl.length)) { value, range, _ in
                    if let value { tv.textStorage.addAttribute(.foregroundColor, value: value, range: range) }
                }
                tv.textStorage.endEditing()
                tv.selectedRange = sel
                tv.setContentOffset(offset, animated: false)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

final class EditorTextView: UITextView {
    var onSave: () -> Void = {}
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [UIKeyCommand(title: "Save", action: #selector(save), input: "s", modifierFlags: .command)]
    }
    @objc func save() { onSave() }
    @objc func undoEdit() { undoManager?.undo() }
    @objc func redoEdit() { undoManager?.redo() }
    @objc func findText() { findInteraction?.presentFindNavigator(showingReplace: false) }
    @objc func copyAll() { UIPasteboard.general.string = text }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let font else { return }
        let source = text as NSString
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var start = source.lineRange(for: NSRange(location: min(chars.location, source.length), length: 0)).location
        var number = source.substring(to: start).filter { $0 == "\n" }.count + 1
        while start < source.length && start <= NSMaxRange(chars) {
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            ("\(number)" as NSString).draw(at: CGPoint(x: 6, y: line.minY + textContainerInset.top),
                withAttributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
            start = NSMaxRange(source.lineRange(for: NSRange(location: start, length: 0)))
            number += 1
        }
    }
}

/// Pinch-zoom and pan for screenshots (UIScrollView: crisp, native feel).
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let s = UIScrollView()
        s.minimumZoomScale = 1; s.maximumZoomScale = 8
        s.delegate = context.coordinator
        s.showsHorizontalScrollIndicator = false; s.showsVerticalScrollIndicator = false
        s.backgroundColor = .clear
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        s.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalTo: s.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: s.frameLayoutGuide.heightAnchor),
            iv.leadingAnchor.constraint(equalTo: s.contentLayoutGuide.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: s.contentLayoutGuide.trailingAnchor),
            iv.topAnchor.constraint(equalTo: s.contentLayoutGuide.topAnchor),
            iv.bottomAnchor.constraint(equalTo: s.contentLayoutGuide.bottomAnchor),
        ])
        context.coordinator.imageView = iv
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        s.addGestureRecognizer(dbl)
        return s
    }
    func updateUIView(_ s: UIScrollView, context: Context) { context.coordinator.imageView?.image = image }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let s = g.view as? UIScrollView else { return }
            if s.zoomScale > 1 { s.setZoomScale(1, animated: true) }
            else { let p = g.location(in: imageView); s.zoom(to: CGRect(x: p.x - 80, y: p.y - 60, width: 160, height: 120), animated: true) }
        }
    }
}
