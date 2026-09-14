import SwiftUI

/// A task's pasted image, drawn under its text: the cropped thumbnail, fit to the text column and
/// capped in height so a tall screenshot can't swallow the note. Double-click (or the hover button)
/// opens it in Quick Look; right-click has the rest.
struct TaskImageView: View {
    static let maxHeight: CGFloat = 200

    /// The uncropped thumbnail; nil while it's still loading.
    let image: CGImage?
    let crop: CGRect
    /// Show the image full size: Quick Look (`false`) or the Preview app (`true`).
    var onOpen: (_ inPreviewApp: Bool) -> Void = { _ in }
    var onRemove: () -> Void = {}

    @State private var hovering = false
    // Memoises the cropped bitmap so a re-render (every frame of a drag) reuses the same image.
    @State private var cache = CroppedImageCache()

    var body: some View {
        if let image, let shown = cache.image(image, crop: crop) {
            Image(decorative: shown, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: Self.maxHeight, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        glyphButton("arrow.up.left.and.arrow.down.right", help: "Quick Look") { onOpen(false) }
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
                    Button("Remove Image", role: .destructive, action: onRemove)
                }
        }
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
