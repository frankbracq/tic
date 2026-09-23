import AppKit
import Foundation
import Testing
@testable import Tic

@MainActor
struct ListPrinterTests {
    private let noteId = UUID()

    private func task(_ text: String, level: Int = 0, done: Bool = false) -> TaskItem {
        TaskItem(noteId: noteId, text: text, isDone: done, indentLevel: level)
    }

    /// The paragraph style and attributes at the first occurrence of `substring`.
    private func attributes(of substring: String, in doc: NSAttributedString) -> [NSAttributedString.Key: Any] {
        let range = (doc.string as NSString).range(of: substring)
        #expect(range.location != NSNotFound, "\(substring) missing")
        return doc.attributes(at: range.location, effectiveRange: nil)
    }

    @Test func titleSummaryAndBoxes() {
        let doc = ListPrinter.document(title: "Groceries", tasks: [task("Milk"), task("Eggs", done: true)])
        let lines = doc.string.components(separatedBy: "\n")
        #expect(lines[0] == "Groceries")
        #expect(lines[1] == "1 of 2 done")
        #expect(lines[2] == "\(ListPrinter.uncheckedBox)\tMilk")
        #expect(lines[3] == "\(ListPrinter.checkedBox)\tEggs")
    }

    @Test func emptyTitleFallsBack() {
        let doc = ListPrinter.document(title: "  ", tasks: [])
        #expect(doc.string.hasPrefix("Untitled List\nNo tasks\n"))
    }

    @Test func doneTasksAreStruckThrough() {
        let doc = ListPrinter.document(title: "T", tasks: [task("open"), task("closed", done: true)])
        #expect(attributes(of: "open", in: doc)[.strikethroughStyle] == nil)
        #expect(attributes(of: "closed", in: doc)[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func nestingIndentsWithHangingIndent() {
        let doc = ListPrinter.document(title: "T", tasks: [task("parent"), task("child", level: 1)])
        let parent = attributes(of: "parent", in: doc)[.paragraphStyle] as? NSParagraphStyle
        let child = attributes(of: "child", in: doc)[.paragraphStyle] as? NSParagraphStyle
        #expect(parent?.firstLineHeadIndent == 0)
        #expect(parent?.headIndent == ListPrinter.textIndent(level: 0))
        #expect(child?.firstLineHeadIndent == ListPrinter.indentStep)
        #expect(child?.headIndent == ListPrinter.textIndent(level: 1))
    }

    @Test func multilineStaysInOneParagraph() {
        let doc = ListPrinter.document(title: "T", tasks: [task("first\nsecond")])
        #expect(doc.string.contains("first\u{2028}second"))
    }

    @Test func inlineMarkdownBecomesFonts() {
        let text = ListPrinter.inlineMarkdown("a **bold** `code` [link](https://example.com)",
                                              size: 12, ink: .black, struck: false)
        #expect(text.string == "a bold code link")
        let bold = attributes(of: "bold", in: text)[.font] as? NSFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let code = attributes(of: "code", in: text)[.font] as? NSFont
        #expect(code?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(attributes(of: "link", in: text)[.link] as? URL == URL(string: "https://example.com"))
    }

    @Test func imagesBecomeAttachmentsFitToWidth() throws {
        let context = CGContext(
            data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        let item = task("photo")
        let doc = ListPrinter.document(title: "T", tasks: [item], images: [item.id: image], width: 300)
        var found: NSTextAttachment?
        doc.enumerateAttribute(.attachment, in: NSRange(location: 0, length: doc.length)) { value, _, _ in
            if let value = value as? NSTextAttachment { found = value }
        }
        let bounds = try #require(found?.bounds)
        #expect(bounds.width > 0 && bounds.width <= 300 - ListPrinter.textIndent(level: 0))
        #expect(bounds.height <= ListPrinter.maxImageHeight)
    }
}
