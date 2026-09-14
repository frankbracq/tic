import SwiftUI

/// A task's pasted image in the note: a small thumbnail under the text, like an attachment. Its size
/// comes from the image alone — never the note's width — so resizing a note can't reflow it, and it has
/// no hover chrome to shift anything. Click opens the image window (zoom, crop); right-click can remove it.
struct TaskImageView: View {
    static let height: CGFloat = 56
    static let maxWidth: CGFloat = 160

    /// The uncropped thumbnail; nil while it's still loading.
    let image: CGImage?
    let crop: CGRect
    var onOpen: () -> Void = {}
    var onRemove: () -> Void = {}

    // Memoises the cropped bitmap so a re-render (every frame of a drag) reuses the same image.
    @State private var cache = CroppedImageCache()

    var body: some View {
        thumbnail
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .help("Open image")
            .contextMenu {
                Button("Open Image", action: onOpen)
                Divider()
                Button("Remove Image", role: .destructive, action: onRemove)
            }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image, let shown = cache.image(image, crop: crop), shown.height > 0 {
            let size = Self.fittedSize(width: CGFloat(shown.width), height: CGFloat(shown.height))
            Image(decorative: shown, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
        } else {
            Color.primary.opacity(0.06)
                .frame(width: Self.height, height: Self.height)
        }
    }

    /// `height` tall at the image's aspect ratio — narrowed (and so shortened) to fit `maxWidth`.
    private static func fittedSize(width: CGFloat, height: CGFloat) -> CGSize {
        let aspect = width / height
        return aspect * Self.height > maxWidth
            ? CGSize(width: maxWidth, height: maxWidth / aspect)
            : CGSize(width: aspect * Self.height, height: Self.height)
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
