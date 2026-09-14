import SwiftUI

/// A task's pasted image, drawn under its text: the cropped thumbnail, fit to the text column and
/// capped in height so a tall screenshot can't swallow the note.
struct TaskImageView: View {
    static let maxHeight: CGFloat = 200

    /// The uncropped thumbnail; nil while it's still loading.
    let image: CGImage?
    let crop: CGRect

    // Memoises the cropped bitmap so a re-render (every frame of a drag) reuses the same image.
    @State private var cache = CroppedImageCache()

    var body: some View {
        if let image, let shown = cache.image(image, crop: crop) {
            Image(decorative: shown, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: Self.maxHeight, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
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
