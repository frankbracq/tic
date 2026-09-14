import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Helpers for a task's pasted image — pure CoreGraphics/ImageIO (no AppKit, no database), so
/// `NoteController` stays AppKit-free and all of this is unit-testable in isolation.
///
/// A crop is a **normalised** rect (0…1) with a **top-left** origin — the same orientation as CGImage
/// pixel space, so it maps straight onto `CGImage.cropping(to:)` with no flip. The original bytes are
/// always what's stored; cropping only ever changes this rect, so it can be reset.
enum TaskImage {
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    // ponytail: stored at full size; downscale in normalizedData if big pastes bloat the database.

    /// Pasted bytes → what gets stored: a PNG as-is, anything else ImageIO reads (clipboard TIFF, a
    /// JPEG/HEIC file…) re-encoded as PNG with its EXIF orientation applied. `nil` if it isn't an image.
    static func normalizedData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { return data }
        return decode(source, maxPixelSize: nil).flatMap(pngData)
    }

    /// A downsampled bitmap for drawing on the note. Rows re-render on every frame of a drag, so the
    /// note only ever draws this — never the full-size image.
    static func thumbnail(_ data: Data, maxPixelSize: Int = 1024) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { decode($0, maxPixelSize: maxPixelSize) }
    }

    /// `image` cropped to the normalised `crop`.
    static func cropped(_ image: CGImage, to crop: CGRect) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pixels = CGRect(
            x: crop.minX * width, y: crop.minY * height,
            width: crop.width * width, height: crop.height * height
        )
        return image.cropping(to: pixels.integral)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Decodes the first frame with its orientation applied; a `nil` `maxPixelSize` keeps full size.
    private static func decode(_ source: CGImageSource, maxPixelSize: Int?) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
