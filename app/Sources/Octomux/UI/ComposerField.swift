import AppKit
import SwiftUI

/// Multi-line message field of the chat composers. Grows with its text between `minLines` and `maxLines`,
/// then scrolls (wheel, trackpad, scroll bar). ↩ sends; ⇧↩ / ⌥↩ add a new line. A SwiftUI vertical
/// `TextField` stops growing at its line limit and cannot be scrolled on macOS, so this wraps an NSTextView.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 14
    var minLines = 2
    var maxLines = 12
    var enabled = true
    @Binding var focused: Bool
    var onSubmit: () -> Void
    /// Called for a paste that carries images or files; return true when it was handled.
    var onPasteFiles: (() -> Bool)? = nil
    /// `/` and `@` menus (keys ↑ ↓ ↩ ⇥ esc go to the menu while it is open).
    var completion: ComposerCompletion? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let tv = ComposerTextView()
        tv.coordinator = context.coordinator
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        // The system's writing-tools badge sits on the field's left edge, over the composer border.
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let sv = ComposerScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.borderType = .noBorder
        sv.documentView = tv
        sv.textView = tv
        context.coordinator.scroll = sv
        completion?.textView = tv
        apply(to: sv, tv)
        tv.string = text
        sv.recalcHeight()
        return sv
    }

    func updateNSView(_ sv: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.textView else { return }
        apply(to: sv, tv)
        if tv.string != text, !tv.hasMarkedText() {
            tv.string = text
            let end = NSRange(location: (text as NSString).length, length: 0)
            tv.setSelectedRange(end)
            tv.scrollRangeToVisible(end)
            sv.recalcHeight()
        }
        // Focus requested from SwiftUI (on appear, after picking a template…).
        if focused, let w = sv.window, w.firstResponder !== tv {
            DispatchQueue.main.async { if self.focused { w.makeFirstResponder(tv) } }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        // Only measures: SwiftUI asks with several widths in one pass, and changing anything here (or asking for
        // another layout) made long text loop forever.
        CGSize(width: proposal.width ?? 300, height: nsView.measure(width: proposal.width))
    }

    private func apply(to sv: ComposerScrollView, _ tv: ComposerTextView) {
        let font = NSFont.systemFont(ofSize: T.k * fontSize)
        if tv.font != font {
            tv.font = font
            tv.typingAttributes[.font] = font
        }
        tv.textColor = NSColor(T.text)
        tv.insertionPointColor = NSColor(T.text)
        tv.placeholder = placeholder
        tv.placeholderColor = NSColor(T.text3)
        tv.isEditable = enabled
        tv.isSelectable = true
        let line = ceil(font.ascender - font.descender + font.leading)
        sv.minHeight = line * CGFloat(minLines)
        sv.maxHeight = line * CGFloat(maxLines)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var scroll: ComposerScrollView?
        init(_ p: ComposerField) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            scroll?.recalcHeight()
            tv.scrollRangeToVisible(tv.selectedRange())
            parent.completion?.update(text: tv.string, caret: tv.selectedRange().location)
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = n.object as? NSTextView, let c = parent.completion, c.isActive || tv.selectedRange().length == 0 else { return }
            c.update(text: tv.string, caret: tv.selectedRange().location)
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if let c = parent.completion, c.isActive {
                switch sel {
                case #selector(NSResponder.moveUp(_:)): c.move(-1); return true
                case #selector(NSResponder.moveDown(_:)): c.move(1); return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): c.accept(); return true
                case #selector(NSResponder.cancelOperation(_:)): c.dismiss(); return true
                default: break
                }
            }
            guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                tv.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }

        func focusChanged(_ on: Bool) {
            guard parent.focused != on else { return }
            DispatchQueue.main.async { self.parent.focused = on }
        }
    }
}

final class ComposerScrollView: NSScrollView {
    weak var textView: ComposerTextView?
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 220
    private(set) var height: CGFloat = 36

    /// Height of the text at `width` (or the width it wraps at now), clamped; scrolls past the maximum. Measured on
    /// an off-screen copy: changing the field's own text system here made it lay out again while drawing, which
    /// resized it, which made SwiftUI measure again (long text looped until AppKit gave up).
    func measure(width: CGFloat?) -> CGFloat {
        guard let tv = textView, let tc = tv.textContainer else { return height }
        let w = (width ?? 0) > 0 ? width! : tc.containerSize.width
        guard w > 0, w < 100_000 else { return height }
        let key = MeasureKey(text: tv.string, width: w, font: tv.font)
        if let last = lastMeasure, last.key == key { return last.height }
        let storage = NSTextStorage(string: tv.string.isEmpty ? " " : tv.string, attributes: [.font: tv.font ?? NSFont.systemFont(ofSize: 13)])
        let lm = NSLayoutManager()
        let c = NSTextContainer(size: NSSize(width: w, height: .greatestFiniteMagnitude))
        c.lineFragmentPadding = tc.lineFragmentPadding
        lm.addTextContainer(c)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: c)
        var used = lm.usedRect(for: c).height
        if tv.string.hasSuffix("\n") { used = max(used, lm.extraLineFragmentRect.maxY) }
        let h = min(max(ceil(used), minHeight), maxHeight)
        lastMeasure = (key, h)
        return h
    }

    private struct MeasureKey: Equatable { var text: String; var width: CGFloat; var font: NSFont? }
    private var lastMeasure: (key: MeasureKey, height: CGFloat)?

    /// After the text or the width on screen changed: a new height asks SwiftUI to lay the field out again.
    func recalcHeight(width: CGFloat? = nil) {
        let h = measure(width: width)
        if abs(h - height) > 0.5 {
            height = h
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    // No height work in layout(): SwiftUI measures the field with sizeThatFits for every width it tries, and asking
    // for another layout from inside one (long text, a field that just appeared) looped until AppKit gave up.
}

final class ComposerTextView: NSTextView {
    weak var coordinator: ComposerField.Coordinator?
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }
    var placeholderColor = NSColor.placeholderTextColor

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.focusChanged(false) }
        return ok
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasImage = pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil
        // A screenshot, or files copied in Finder (they also carry their names as text).
        if hasImage || hasFiles, let handler = coordinator?.parent.onPasteFiles, handler() {
            return
        }
        pasteAsPlainText(sender)
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: placeholderColor]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
