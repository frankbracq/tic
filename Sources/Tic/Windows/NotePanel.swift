import AppKit
import Quartz
import SwiftUI

/// A single sticky note window. A titled panel with a hidden, transparent title bar gives us
/// rounded corners, a system shadow, and edge resizing for free, while `fullSizeContentView`
/// lets the SwiftUI content cover the whole surface. `nonactivatingPanel` keeps clicking a note
/// from yanking the whole app forward — it behaves like a desktop sticky.
final class NotePanel: NSPanel {
    let noteID: UUID

    init(note: Note, content: AnyView) {
        self.noteID = note.id

        let rect = NSRect(x: note.frameX, y: note.frameY, width: note.frameW, height: note.frameH)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The window is dragged only by its header (a WindowMoveArea), NOT the whole body —
        // otherwise starting a task-row drag would move the window instead of reordering.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false            // stay visible when another app is focused
        isOpaque = false
        backgroundColor = .clear             // let the SwiftUI background (incl. glass) show through
        hasShadow = true
        isReleasedWhenClosed = false         // the window manager owns the lifetime
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 200, height: 160)

        // Hide the traffic-light buttons; notes get their own controls in the header.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        apply(floatOnTop: note.floatOnTop, showOnAllSpaces: note.showOnAllSpaces)
    }

    /// Applies the float-on-top and show-on-all-Spaces behaviours to the live window.
    func apply(floatOnTop: Bool, showOnAllSpaces: Bool) {
        level = floatOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
        if showOnAllSpaces { behavior.insert(.canJoinAllSpaces) }
        collectionBehavior = behavior
    }

    /// Borderless/utility panels don't become key by default; we need it for text editing.
    override var canBecomeKey: Bool { true }

    // MARK: - Paste

    /// Adds a pasted image as a new task. Reached when nothing in the note is being edited — a focused
    /// editor handles ⌘V itself, earlier in the responder chain. Set by `NoteWindowManager`.
    var onPasteImage: ((Data) -> Void)?

    @objc func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.pastableImageData() { onPasteImage?(data) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.hasPastableImage }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Quick Look

    /// The file Quick Look shows for this note (a temp PNG of the cropped image).
    private var previewURL: URL?

    /// Opens (or retargets) the shared Quick Look panel on `url`. Quick Look finds its controller in
    /// the key window's responder chain, so the note makes itself key first — and, as a non-activating
    /// panel, activates the app so the preview comes up in front rather than behind the frontmost app.
    func showQuickLook(_ url: URL) {
        previewURL = url
        NSApp.activate()
        makeKey()
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.updateController()
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // Quick Look's controller hooks are a nonisolated NSObject category, but it only calls them on the
    // main thread.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewURL != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
}

extension NotePanel: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
