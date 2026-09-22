import AppKit

/// Prints a list as a plain paper checklist: the title, then one row per task with a ☐/☑ box,
/// nesting shown as indentation, inline Markdown kept (bold, italic, `code`, ~~strike~~), finished
/// tasks struck through in grey, and each task's (cropped) image under its row.
///
/// Ink is always black-on-white, whatever the note's colour or material — it's paper, not a screenshot.
/// The document is built as an `NSAttributedString` (`document(…)`, pure and unit-tested), laid into an
/// `NSTextView`, and handed to `NSPrintOperation`, which paginates it and offers Save as PDF for free.
@MainActor
enum ListPrinter {
    /// Horizontal step per nesting level.
    static let indentStep: CGFloat = 18
    /// Width of the checkbox column (the text wraps back to this, not under the box).
    static let boxWidth: CGFloat = 20
    static let maxImageHeight: CGFloat = 220

    static let uncheckedBox = "☐"
    static let checkedBox = "☑"

    /// Shows the system print panel for a list. `tasks` is what the note displays (so its hide / sink
    /// completed options apply); `images` are the tasks' bitmaps, already cropped, keyed by task id.
    static func print(title: String, tasks: [TaskItem], images: [UUID: CGImage]) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 48
        info.bottomMargin = 48
        info.leftMargin = 54
        info.rightMargin = 54
        info.jobDisposition = .spool

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let text = document(title: title, tasks: tasks, images: images, width: width)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        _ = view.layoutManager   // force TextKit 1, so usedRect can size the view (see PlainTextEditor)
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(text)
        if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height)
            view.setFrameSize(NSSize(width: width, height: max(height, 1)))
        }

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = displayTitle(title)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling])
        // Notes are non-activating panels: bring Tic forward so the print panel lands in front, key.
        NSApp.activate()
        operation.run()
    }

    static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled List" : trimmed
    }

    // MARK: - Document

    /// The printable document. `width` is the printable page width, used to fit images.
    static func document(
        title: String, tasks: [TaskItem], images: [UUID: CGImage] = [:], width: CGFloat = 480
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 4
        result.append(NSAttributedString(string: displayTitle(title) + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: titleStyle,
        ]))

        let done = tasks.filter(\.isDone).count
        let summaryStyle = NSMutableParagraphStyle()
        summaryStyle.paragraphSpacing = 14
        let summary = tasks.isEmpty ? "No tasks" : "\(done) of \(tasks.count) done"
        result.append(NSAttributedString(string: summary + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: summaryStyle,
        ]))

        for task in tasks {
            result.append(row(task))
            if let image = images[task.id] {
                result.append(imageParagraph(image, level: task.indentLevel, width: width))
            }
        }
        return result
    }

    /// Indentation of a row's text (after its box) for `level`.
    static func textIndent(level: Int) -> CGFloat {
        CGFloat(max(level, 0)) * indentStep + boxWidth
    }

    /// One task: `☐<tab>text`, with a hanging indent so wrapped and multiline text stays aligned
    /// right of the box. Line breaks inside a task become U+2028 (same paragraph, same indent).
    private static func row(_ task: TaskItem) -> NSAttributedString {
        let boxIndent = CGFloat(max(task.indentLevel, 0)) * indentStep
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = boxIndent
        style.headIndent = textIndent(level: task.indentLevel)
        style.tabStops = [NSTextTab(textAlignment: .left, location: textIndent(level: task.indentLevel))]
        style.paragraphSpacing = 5

        let size: CGFloat = task.indentLevel == 0 ? 12 : 11
        let ink: NSColor = task.isDone ? .gray : .black
        let line = NSMutableAttributedString(
            string: (task.isDone ? checkedBox : uncheckedBox) + "\t",
            attributes: [.font: NSFont.systemFont(ofSize: size + 1), .foregroundColor: ink]
        )
        line.append(inlineMarkdown(task.text, size: size, ink: ink, struck: task.isDone))
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// The task text with inline Markdown turned into real fonts (AppKit doesn't render the
    /// presentation intents `AttributedString(markdown:)` produces), links kept as links.
    static func inlineMarkdown(_ text: String, size: CGFloat, ink: NSColor, struck: Bool) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let result = NSMutableAttributedString()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\u{2028}")) }
            let parsed = (try? AttributedString(markdown: String(line), options: options))
                ?? AttributedString(String(line))
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = intent.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                    : NSFont.systemFont(ofSize: size)
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor
                        .withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                if struck || intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = run.link {
                    attributes[.link] = link
                    if !struck { attributes[.foregroundColor] = NSColor.linkColor }
                }
                let piece = String(parsed[run.range].characters)
                result.append(NSAttributedString(string: piece, attributes: attributes))
            }
        }
        return result
    }

    /// A task's image on its own paragraph, aligned with the task's text and scaled to fit.
    private static func imageParagraph(_ image: CGImage, level: Int, width: CGFloat) -> NSAttributedString {
        let indent = textIndent(level: level)
        let fitted = TaskImage.fittedSize(
            aspect: CGFloat(image.width) / CGFloat(max(image.height, 1)),
            maxWidth: min(max(width - indent, 40), CGFloat(image.width)),
            maxHeight: min(maxImageHeight, CGFloat(image.height))
        )
        let attachment = NSTextAttachment()
        attachment.image = NSImage(cgImage: image, size: fitted)
        attachment.bounds = CGRect(origin: .zero, size: fitted)

        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacing = 8
        let paragraph = NSMutableAttributedString(attachment: attachment)
        paragraph.append(NSAttributedString(string: "\n"))
        let whole = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.paragraphStyle, value: style, range: whole)
        return paragraph
    }
}
