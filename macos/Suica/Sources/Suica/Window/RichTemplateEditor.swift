import AppKit
import SuicaCore
import SwiftUI

extension NSAttributedString.Key {
    /// The placeholder name on a chip's attachment character.
    static let suicaPlaceholder = NSAttributedString.Key("suicaPlaceholder")
    /// `[alt, url]` on a GIF chip's attachment character.
    static let suicaImage = NSAttributedString.Key("suicaImage")
}

/// What the format bar asks of the editor: it acts on the text view's selection.
@MainActor
final class RichEditorController {
    fileprivate weak var textView: TemplateTextView?
    fileprivate var emoji: [String: String] = [:]

    func toggle(_ style: TemplateStyle) { textView?.toggle(style) }
    func insertPlaceholder(_ name: String) { textView?.insertRuns([.placeholder(name, [])]) }
    func insertImage(alt: String, url: String) { textView?.insertRuns([.image(alt: alt, url: url)]) }
    func insertText(_ text: String) { textView?.insertRuns([.text(text, [])]) }
    func editLink() { textView?.editLink() }

    /// The system Emoji & Symbols palette, typing into the editor.
    func showCharacterPalette() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        NSApp.orderFrontCharacterPalette(textView)
    }
}

/// The visual template editor: formatted text with placeholder and GIF chips, read from and
/// written to the template's Markdown (`TemplateMarkup`). Copy writes Markdown, so chips paste
/// back as chips; text pasted from elsewhere is taken literally.
struct RichTemplateEditor: NSViewRepresentable {
    @Binding var markdown: String
    let controller: RichEditorController
    let emoji: [String: String]
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TemplateTextView(usingTextLayoutManager: false)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.typingAttributes = TemplateTextView.baseAttributes
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.load(markdown)
        context.coordinator.written = markdown

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        controller.textView = textView
        controller.emoji = emoji
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? TemplateTextView else { return }
        controller.textView = textView
        controller.emoji = emoji
        // Only text that changed outside the editor (another variant, Revert) is loaded again,
        // so typing keeps its selection and undo history.
        if markdown != context.coordinator.written {
            textView.load(markdown)
            context.coordinator.written = markdown
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTemplateEditor
        /// The Markdown the editor last wrote or loaded.
        var written = ""
        private var typedColon = false

        init(_ parent: RichTemplateEditor) { self.parent = parent }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            typedColon = replacementString == ":"
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TemplateTextView else { return }
            if typedColon { completeShortcode(in: textView) }
            typedColon = false
            let markdown = textView.markdown()
            written = markdown
            if parent.markdown != markdown { parent.markdown = markdown }
        }

        /// Typing a known `:name:` puts the emoji in its place.
        private func completeShortcode(in textView: NSTextView) {
            let caret = textView.selectedRange().location
            let before = (textView.string as NSString).substring(to: caret)
            guard let (length, emoji) = EmojiShortcodes.completed(in: before, table: parent.emoji) else { return }
            let range = NSRange(location: caret - length, length: length)
            if textView.shouldChangeText(in: range, replacementString: emoji) {
                textView.textStorage?.replaceCharacters(
                    in: range, with: NSAttributedString(string: emoji, attributes: textView.typingAttributes))
                textView.didChangeText()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Text typed after a chip or a link is plain text, not part of them.
            var typing = textView.typingAttributes
            for key in [NSAttributedString.Key.attachment, .suicaPlaceholder, .suicaImage, .link] { typing[key] = nil }
            if typing[.font] == nil { typing[.font] = TemplateTextView.baseFont }
            typing[.foregroundColor] = NSColor.labelColor
            if !NSDictionary(dictionary: typing).isEqual(to: textView.typingAttributes) { textView.typingAttributes = typing }
        }
    }
}

// MARK: - Text view

final class TemplateTextView: NSTextView {
    static let baseFont = NSFont.systemFont(ofSize: 13)
    static let baseAttributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.labelColor]
    private static let markdownType = NSPasteboard.PasteboardType("id.suica.template-markdown")

    func load(_ markdown: String) {
        let text = Self.attributed(TemplateMarkup.parse(markdown))
        textStorage?.setAttributedString(text)
        setSelectedRange(NSRange(location: text.length, length: 0))
        typingAttributes = Self.baseAttributes
    }

    func markdown() -> String { TemplateMarkup.markdown(runs(in: NSRange(location: 0, length: textStorage?.length ?? 0))) }

    // MARK: Runs and attributed text

    static func attributed(_ runs: [TemplateRun]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            switch run {
            case .text(let text, let style):
                result.append(NSAttributedString(string: text, attributes: attributes(style)))
            case .link(let text, let url, let style):
                var attributes = attributes(style)
                attributes[.link] = URL(string: url)
                result.append(NSAttributedString(string: text, attributes: attributes))
            case .placeholder(let name, let style):
                result.append(chip(label: Copy.placeholderChip(name), symbol: "curlybraces", key: .suicaPlaceholder, value: name, style: style))
            case .image(let alt, let url):
                result.append(chip(label: alt.isEmpty ? "GIF" : "GIF · \(alt)", symbol: "photo", key: .suicaImage, value: [alt, url], style: []))
            }
        }
        return result
    }

    private static func attributes(_ style: TemplateStyle) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        var font = baseFont
        if style.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if style.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        attributes[.font] = font
        if style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    /// A rounded chip that moves and deletes as one character; the label is what it stands for.
    private static func chip(
        label: String, symbol: String, key: NSAttributedString.Key, value: Any, style: TemplateStyle
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor])
        let iconSize: CGFloat = 11
        let size = NSSize(width: ceil(text.size().width) + iconSize + 16, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            shape.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            shape.stroke()
            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [.controlAccentColor])))
            {
                icon.draw(in: NSRect(x: 6, y: (rect.height - iconSize) / 2, width: iconSize, height: iconSize))
            }
            text.draw(at: NSPoint(x: iconSize + 10, y: (rect.height - text.size().height) / 2))
            return true
        }
        image.accessibilityDescription = label
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: baseFont.descender - 1, width: size.width, height: size.height)
        let chip = NSMutableAttributedString(attachment: attachment)
        var attributes = attributes(style)
        attributes[key] = value
        chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    func runs(in range: NSRange) -> [TemplateRun] {
        guard let storage = textStorage else { return [] }
        var runs: [TemplateRun] = []
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            let text = (storage.string as NSString).substring(with: subrange)
            let style = Self.style(of: attributes)
            if text == "\u{FFFC}" || attributes[.attachment] != nil {
                // One chip per attachment character; an attachment of unknown origin is dropped.
                for _ in 0..<text.utf16.count {
                    if let name = attributes[.suicaPlaceholder] as? String {
                        runs.append(.placeholder(name, style))
                    } else if let image = attributes[.suicaImage] as? [String], image.count == 2 {
                        runs.append(.image(alt: image[0], url: image[1]))
                    }
                }
                return
            }
            let plain = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            if let url = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String {
                runs.append(.link(text: plain, url: url, style))
            } else if !plain.isEmpty {
                runs.append(.text(plain, style))
            }
        }
        return runs
    }

    private static func style(of attributes: [NSAttributedString.Key: Any]) -> TemplateStyle {
        var style: TemplateStyle = []
        if let font = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { style.insert(.bold) }
            if traits.contains(.italicFontMask) { style.insert(.italic) }
        }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { style.insert(.strikethrough) }
        return style
    }

    // MARK: Editing

    func insertRuns(_ runs: [TemplateRun]) {
        window?.makeFirstResponder(self)
        let text = Self.attributed(runs)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        didChangeText()
    }

    /// Turns `style` on for the selection, or off when all of it already has it; with nothing
    /// selected it applies to what is typed next.
    func toggle(_ style: TemplateStyle) {
        window?.makeFirstResponder(self)
        let range = selectedRange()
        guard let storage = textStorage else { return }
        if range.length == 0 {
            var typing = typingAttributes
            let on = !Self.style(of: typing).contains(style)
            apply(style, on: on, to: &typing)
            typingAttributes = typing
            return
        }
        var all = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if !Self.style(of: attributes).contains(style) {
                all = false
                stop.pointee = true
            }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var changed = attributes
            apply(style, on: !all, to: &changed)
            storage.setAttributes(changed, range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    private func apply(_ style: TemplateStyle, on: Bool, to attributes: inout [NSAttributedString.Key: Any]) {
        if style == .strikethrough {
            attributes[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : nil
            return
        }
        let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
        let font = attributes[.font] as? NSFont ?? Self.baseFont
        attributes[.font] =
            on ? NSFontManager.shared.convert(font, toHaveTrait: trait) : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
    }

    /// Asks for an http(s) address and links the selection to it, or removes the link there.
    func editLink() {
        let range = selectedRange()
        guard let window, range.length > 0 else {
            NSSound.beep()
            return
        }
        let current = textStorage?.attribute(.link, at: range.location, effectiveRange: nil)
        let field = NSTextField(string: (current as? URL)?.absoluteString ?? "https://")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = Copy.formatLinkPrompt
        alert.accessoryView = field
        alert.addButton(withTitle: Copy.formatLinkAdd)
        alert.addButton(withTitle: Copy.confirmCancel)
        if current != nil { alert.addButton(withTitle: Copy.formatLinkRemove) }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard let url = DisplayText.safeURL(Self.encoded(field.stringValue)) else {
                    NSSound.beep()
                    return
                }
                self.setLink(url, in: range)
            case .alertThirdButtonReturn:
                self.setLink(nil, in: range)
            default:
                break
            }
        }
    }

    private func setLink(_ url: URL?, in range: NSRange) {
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        if let url {
            textStorage?.addAttribute(.link, value: url, range: range)
        } else {
            textStorage?.removeAttribute(.link, range: range)
        }
        didChangeText()
    }

    /// Characters that would end a Markdown link target are percent-encoded, as the agent does.
    static func encoded(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespaces).replacing(/[ ()<>]/) { match in
            "%" + String(format: "%02X", match.output.unicodeScalars.first?.value ?? 0)
        }
    }

    // MARK: Pasteboard

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        NSPasteboard.general.clearContents()
        _ = writeSelection(to: .general, types: [Self.markdownType, .string])
    }

    /// Copying and dragging write the selection as Markdown, so chips and styles survive.
    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let markdown = TemplateMarkup.markdown(runs(in: selectedRange()))
        pasteboard.declareTypes([Self.markdownType, .string], owner: nil)
        return pasteboard.setString(markdown, forType: Self.markdownType) && pasteboard.setString(markdown, forType: .string)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [Self.markdownType, .string] }

    /// Pasting and dropping: Markdown from this editor keeps its chips; other text is literal.
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == Self.markdownType, let markdown = pasteboard.string(forType: Self.markdownType) {
            insertRuns(TemplateMarkup.parse(markdown))
            return true
        }
        if let text = pasteboard.string(forType: .string) {
            insertRuns([.text(text, [])])
            return true
        }
        return false
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        let range = selectedRange()
        if shouldChangeText(in: range, replacementString: "") {
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
        }
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let type = pasteboard.availableType(from: [Self.markdownType, .string])
        if let type { _ = readSelection(from: pasteboard, type: type) }
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [Self.markdownType, .string] }
}
