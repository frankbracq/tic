import AppKit
import SwiftUI

/// The image window: a task's image, large. Pinch, ⌘-scroll or ⌘+ / ⌘− / ⌘0 zoom it; scrolling pans.
/// **Crop** shows the whole, uncropped image fitted to the window with the discarded area dimmed and a
/// bracket on each corner of the kept area — drag a bracket to resize, drag elsewhere to slide; ⏎ or Done
/// keeps it, ⎋ or Cancel discards. The crop is a normalised rect over the stored original, so Reset Crop
/// restores it. Hosted in the one reusable window `NoteWindowManager` owns; closes itself if the image
/// goes away.
struct ImageViewer: View {
    let controller: NoteController
    let taskId: UUID
    let onClose: () -> Void

    /// The stored image at full resolution, uncropped; nil while loading.
    @State private var image: CGImage?
    /// The crop being edited; non-nil exactly while cropping.
    @State private var draftCrop: CGRect?
    @State private var cache = CroppedImageCache()

    private var crop: CGRect? { controller.imageCrops[taskId] }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { image = await controller.fullImage(taskId: taskId) }
        .onChange(of: crop == nil) { _, removed in
            if removed { onClose() }
        }
    }

    // MARK: - Bar

    private var bar: some View {
        HStack(spacing: 8) {
            if draftCrop != nil {
                Text("Drag the corners to crop")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { endCrop(save: false) }
                Button("Done") { endCrop(save: true) }
            } else {
                Spacer()
                Button { beginCrop() } label: { Label("Crop", systemImage: "crop") }
                    .disabled(image == nil)
                Button("Reset Crop") { save(TaskImage.fullCrop) }
                    .disabled(crop == TaskImage.fullCrop)
                Menu {
                    Button("Open in Preview") { openInPreview() }
                    Divider()
                    Button("Remove Image", role: .destructive) { remove() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Image

    @ViewBuilder
    private var content: some View {
        if let image, let crop {
            if let draftCrop {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { GeometryReader { geo in cropOverlay(crop: draftCrop, size: geo.size) } }
                    .padding(24)
            } else if let shown = cache.image(image, crop: crop) {
                ZoomableImage(image: shown)
            }
        } else {
            ProgressView()
        }
    }

    /// The dimmed discard area, the kept-area outline and the four corner brackets — drawn only; the
    /// `CropInteraction` laid over them takes every click and key.
    private func cropOverlay(crop: CGRect, size: CGSize) -> some View {
        let box = CGRect(
            x: crop.minX * size.width, y: crop.minY * size.height,
            width: crop.width * size.width, height: crop.height * size.height
        )
        return ZStack {
            Group {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

                Rectangle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)

                ForEach(TaskImage.Corner.allCases, id: \.self) { corner in
                    bracket(corner)
                        .position(x: corner.isLeading ? box.minX : box.maxX, y: corner.isTop ? box.minY : box.maxY)
                }
            }
            .allowsHitTesting(false)

            CropInteraction(
                crop: crop,
                onChange: { draftCrop = $0 },
                onDone: { endCrop(save: true) },
                onCancel: { endCrop(save: false) }
            )
        }
        .frame(width: size.width, height: size.height)
    }

    /// An L-shaped bracket whose vertex sits on the crop corner, arms pointing into the kept area.
    private func bracket(_ corner: TaskImage.Corner) -> some View {
        let side: CGFloat = 22, arm: CGFloat = 10
        let vertex = CGPoint(x: side / 2, y: side / 2)
        return Path { path in
            path.move(to: CGPoint(x: vertex.x + (corner.isLeading ? arm : -arm), y: vertex.y))
            path.addLine(to: vertex)
            path.addLine(to: CGPoint(x: vertex.x, y: vertex.y + (corner.isTop ? arm : -arm)))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
        .shadow(color: .black.opacity(0.4), radius: 1)
        .frame(width: side, height: side)
    }

    // MARK: - Actions

    private func beginCrop() {
        draftCrop = crop
    }

    /// Leaves crop mode, saving the draft (⏎, Done, click-away) or discarding it (⎋, Cancel).
    private func endCrop(save shouldSave: Bool) {
        guard let draft = draftCrop else { return }
        draftCrop = nil   // first, so the focus loss this triggers finds nothing left to save
        if shouldSave { save(draft) }
    }

    private func save(_ newCrop: CGRect) {
        guard let task = controller.tasks.first(where: { $0.id == taskId }) else { return }
        controller.setCrop(newCrop, for: task)
    }

    private func remove() {
        guard let task = controller.tasks.first(where: { $0.id == taskId }) else { return }
        controller.removeImage(from: task)   // its crop disappears, which closes this window
    }

    private func openInPreview() {
        Task {
            guard let url = await controller.previewFile(taskId: taskId) else { return }
            let workspace = NSWorkspace.shared
            if let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                _ = try? await workspace.open([url], withApplicationAt: preview, configuration: .init())
            } else {
                workspace.open(url)
            }
        }
    }
}

// MARK: - Crop input (AppKit)

/// Hosts `CropTrackingView` over the crop visuals, feeding it the current crop and callbacks.
struct CropInteraction: NSViewRepresentable {
    let crop: CGRect
    let onChange: (CGRect) -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CropTrackingView { CropTrackingView() }

    func updateNSView(_ view: CropTrackingView, context: Context) {
        view.crop = crop
        view.onChange = onChange
        view.onDone = onDone
        view.onCancel = onCancel
    }
}

/// The mouse and keyboard half of crop mode — AppKit, not SwiftUI, on purpose. A SwiftUI `DragGesture`
/// here could miss its mouse-up (the crop kept following the pointer after release, swallowing every
/// later click), and SwiftUI focus never reliably reached the crop view (⏎ / ⎋ / click-away did
/// nothing). AppKit always sends `mouseDragged`/`mouseUp` to the view that got the `mouseDown`, and a
/// first responder gets its keys deterministically — the same reason the task editor is an `NSTextView`.
final class CropTrackingView: NSView {
    /// How close (in points) to a corner a press must land to drag that corner rather than slide the crop.
    static let cornerReach: CGFloat = 14

    var crop = TaskImage.fullCrop
    var onChange: (CGRect) -> Void = { _ in }
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}

    /// The drag in progress, from mouse-down to mouse-up.
    private struct Drag {
        let startCrop: CGRect
        let startPoint: CGPoint
        let corner: TaskImage.Corner?   // nil = sliding the whole crop
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }   // top-left origin, matching the normalised crop
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Takes the keyboard as soon as crop mode appears, so ⏎ / ⎋ work without a click first.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        drag = Drag(startCrop: crop, startPoint: point, corner: corner(near: point))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGSize(
            width: (point.x - drag.startPoint.x) / bounds.width,
            height: (point.y - drag.startPoint.y) / bounds.height
        )
        if let corner = drag.corner {
            onChange(TaskImage.dragging(drag.startCrop, corner: corner, by: delta))
        } else {
            onChange(TaskImage.moving(drag.startCrop, by: delta))
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onDone()     // Return, keypad Enter
        case 53: onCancel()       // Escape
        default: super.keyDown(with: event)
        }
    }

    /// Something else taking first responder ends cropping, keeping the crop.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onDone() }
        return resigned
    }

    /// The crop corner within `cornerReach` of `point`, if any.
    private func corner(near point: CGPoint) -> TaskImage.Corner? {
        TaskImage.Corner.allCases.first { corner in
            let x = (corner.isLeading ? crop.minX : crop.maxX) * bounds.width
            let y = (corner.isTop ? crop.minY : crop.maxY) * bounds.height
            return abs(point.x - x) <= Self.cornerReach && abs(point.y - y) <= Self.cornerReach
        }
    }
}

// MARK: - Zoom (AppKit)

/// The image in a magnifying scroll view — SwiftUI has no pinch-to-zoom scroll view on macOS 14.
struct ZoomableImage: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> ZoomScrollView { ZoomScrollView() }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.show(image)
    }
}

/// Fits the image to the view to start — and keeps it fitted while the window resizes — until you zoom:
/// pinch, ⌘-scroll, or ⌘+ / ⌘− (⌘0 fits again). Scrolling pans. The image is laid out at one point per
/// pixel and `magnification` does all the scaling.
final class ZoomScrollView: NSScrollView {
    static let zoomStep: CGFloat = 1.25

    private let imageView = NSImageView()
    private var shownImage: CGImage?
    /// True until the user zooms; while true, resizing re-fits the image.
    private var fitsWindow = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteringClipView()
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 16
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        imageView.imageScaling = .scaleAxesIndependently
        documentView = imageView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows `image` fitted to the view (a no-op when it's already the one shown).
    func show(_ image: CGImage) {
        guard image !== shownImage else { return }
        shownImage = image
        let size = NSSize(width: image.width, height: image.height)
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.frame = NSRect(origin: .zero, size: size)
        zoomToFit()
    }

    /// Fits the whole image in view, never enlarging it past one point per pixel.
    func zoomToFit() {
        fitsWindow = true
        let image = imageView.frame.size, visible = contentSize
        guard image.width > 0, image.height > 0, visible.width > 0, visible.height > 0 else { return }
        magnification = min(visible.width / image.width, visible.height / image.height, 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitsWindow { zoomToFit() }
    }

    override func magnify(with event: NSEvent) {
        fitsWindow = false
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let perTick: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        let factor = min(max(1 + event.scrollingDeltaY * perTick, 0.5), 2)
        zoom(by: factor, around: imageView.convert(event.locationInWindow, from: nil))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoom(by: Self.zoomStep)
        case "-": zoom(by: 1 / Self.zoomStep)
        case "0": zoomToFit()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Zooms by `factor`, keeping `point` (image coordinates; default: the middle of the view) in place.
    private func zoom(by factor: CGFloat, around point: NSPoint? = nil) {
        fitsWindow = false
        let visible = documentVisibleRect
        setMagnification(magnification * factor, centeredAt: point ?? NSPoint(x: visible.midX, y: visible.midY))
    }
}

/// Keeps a document smaller than the view centred, instead of pinned to the bottom-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width { rect.origin.x = (documentView.frame.width - rect.width) / 2 }
        if rect.height > documentView.frame.height { rect.origin.y = (documentView.frame.height - rect.height) / 2 }
        return rect
    }
}
