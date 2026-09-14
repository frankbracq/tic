import SwiftUI

/// A task's pasted image, drawn under its text: the cropped thumbnail, filling the text column — so
/// resizing the note resizes it — but never past its real size, so a small image doesn't blur. Hover
/// reveals crop / Quick Look buttons; double-click opens Quick Look; right-click has the rest.
///
/// **Crop mode** shows the whole image with the discarded area dimmed and a bracket on each corner of
/// the kept area: drag a bracket to resize, drag anywhere else to slide the crop. ⏎ (or click-away)
/// keeps it, ⎋ cancels. The crop is only a normalised rect over the stored original — never destructive.
/// Its gestures sit on views inside the row, so they take precedence over the row's reorder drag.
struct TaskImageView: View {
    /// The uncropped thumbnail; nil while it's still loading.
    let image: CGImage?
    let crop: CGRect
    let theme: NoteTheme
    var onCrop: (CGRect) -> Void = { _ in }
    /// Show the image full size: Quick Look (`false`) or the Preview app (`true`).
    var onOpen: (_ inPreviewApp: Bool) -> Void = { _ in }
    var onRemove: () -> Void = {}

    @State private var hovering = false
    /// The crop being edited; non-nil exactly while in crop mode.
    @State private var draftCrop: CGRect?
    /// `draftCrop` as it was when the current drag began — each drag applies its whole translation to it.
    @State private var dragStartCrop: CGRect?
    @FocusState private var cropFocused: Bool
    @Environment(\.displayScale) private var displayScale
    // Memoises the cropped bitmap so a re-render (every frame of a drag) reuses the same image.
    @State private var cache = CroppedImageCache()

    var body: some View {
        if let image {
            if let draftCrop {
                cropEditor(image, crop: draftCrop)
            } else if let shown = cache.image(image, crop: crop) {
                display(shown)
            }
        }
    }

    // MARK: - Display

    private func display(_ shown: CGImage) -> some View {
        Image(decorative: shown, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: realWidth(shown), alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 4) {
                        glyphButton("crop", help: "Crop") { beginCrop() }
                        glyphButton("arrow.up.left.and.arrow.down.right", help: "Quick Look") { onOpen(false) }
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .onHover { inside in withAnimation(.easeInOut(duration: 0.12)) { hovering = inside } }
            .onTapGesture(count: 2) { onOpen(false) }
            .contextMenu {
                Button("Quick Look") { onOpen(false) }
                Button("Open in Preview") { onOpen(true) }
                Divider()
                Button("Crop") { beginCrop() }
                Button("Reset Crop") { onCrop(TaskImage.fullCrop) }
                    .disabled(crop == TaskImage.fullCrop)
                Divider()
                Button("Remove Image", role: .destructive, action: onRemove)
            }
    }

    /// The width, in points, at which `image` shows at its real pixel size on this display.
    private func realWidth(_ image: CGImage) -> CGFloat {
        CGFloat(image.width) / max(displayScale, 1)
    }

    /// A small glyph on a frosted disc, legible over any picture.
    private func glyphButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Crop mode

    private func cropEditor(_ image: CGImage, crop: CGRect) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: realWidth(image))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay { GeometryReader { geo in cropOverlay(crop: crop, size: geo.size) } }

            HStack(spacing: 10) {
                hintButton(glyphs: "⏎", label: "done") { endCrop(save: true) }
                hintButton(glyphs: "⎋", label: "cancel") { endCrop(save: false) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($cropFocused)
        .onKeyPress(.return) { endCrop(save: true); return .handled }
        .onKeyPress(.escape) { endCrop(save: false); return .handled }
        .onAppear { cropFocused = true }
        .onChange(of: cropFocused) { _, focused in
            if !focused { endCrop(save: true) }   // clicking away keeps the crop
        }
    }

    /// The dimmed discard area, the kept-area outline, and the four corner brackets, in view points.
    private func cropOverlay(crop: CGRect, size: CGSize) -> some View {
        let box = CGRect(
            x: crop.minX * size.width, y: crop.minY * size.height,
            width: crop.width * size.width, height: crop.height * size.height
        )
        return ZStack {
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
                    .gesture(cropDrag(in: size) { TaskImage.dragging($0, corner: corner, by: $1) })
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        // Dragging anywhere but a bracket slides the crop (and keeps the row's reorder drag out of it).
        .gesture(cropDrag(in: size) { TaskImage.moving($0, by: $1) })
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
        .contentShape(Rectangle())
    }

    /// A drag that rewrites the draft crop from where it stood when the drag began, with the translation
    /// converted to normalised units.
    private func cropDrag(in size: CGSize, _ apply: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0, let start = dragStartCrop ?? draftCrop else { return }
                dragStartCrop = start
                let delta = CGSize(
                    width: value.translation.width / size.width,
                    height: value.translation.height / size.height
                )
                draftCrop = apply(start, delta)
            }
            .onEnded { _ in dragStartCrop = nil }
    }

    /// A shortcut hint that's also clickable, so crop mode can be left with the mouse too.
    private func hintButton(glyphs: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ShortcutHint(glyphs: glyphs, label: label, theme: theme)
        }
        .buttonStyle(.plain)
    }

    private func beginCrop() {
        hovering = false
        draftCrop = crop
    }

    /// Leaves crop mode, saving the draft (⏎, "done", click-away) or discarding it (⎋, "cancel").
    private func endCrop(save: Bool) {
        guard let draft = draftCrop else { return }
        draftCrop = nil   // first, so the focus loss this triggers finds nothing left to save
        dragStartCrop = nil
        if save, draft != crop { onCrop(draft) }
    }
}

/// Caches `image` cropped to `crop`, recomputing only when either actually changes — the cropped
/// `CGImage` is a new object each time, and handing SwiftUI a fresh one every frame would redraw it.
@MainActor
final class CroppedImageCache {
    private var source: CGImage?
    private var crop = CGRect.null
    private var value: CGImage?

    func image(_ image: CGImage, crop: CGRect) -> CGImage? {
        if image === source, crop == self.crop { return value }
        source = image
        self.crop = crop
        value = TaskImage.cropped(image, to: crop)
        return value
    }
}
