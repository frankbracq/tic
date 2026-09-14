import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Tic

// MARK: - Fixtures

/// A test bitmap: red over the top half, blue over the bottom — so a crop's orientation is checkable.
private func makeImage(width: Int = 100, height: Int = 50) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))   // CG's y is up
    return context.makeImage()!
}

private func encode(_ image: CGImage, as type: UTType) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func imageType(_ data: Data) -> String? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
}

/// The image averaged down to one pixel, as (red, blue).
private func averageColor(_ image: CGImage) -> (red: UInt8, blue: UInt8) {
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { bytes in
        let context = CGContext(
            data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return (pixel[0], pixel[2])
}

private func firstCrops(_ db: AppDatabase, _ noteId: UUID) async throws -> [UUID: CGRect] {
    for try await crops in db.observeTaskImageCrops(noteId: noteId) { return crops }
    return [:]
}

// MARK: - Pure helpers

@Suite("TaskImage")
struct TaskImageTests {
    @Test("PNG is stored as-is; other formats are re-encoded as PNG; non-images are rejected")
    func normalizedData() throws {
        let png = encode(makeImage(), as: .png)
        #expect(TaskImage.normalizedData(png) == png)

        let converted = try #require(TaskImage.normalizedData(encode(makeImage(), as: .tiff)))
        #expect(imageType(converted) == UTType.png.identifier)

        #expect(TaskImage.normalizedData(Data("not an image".utf8)) == nil)
    }

    @Test("the thumbnail is downsampled to the max pixel size, keeping the aspect ratio")
    func thumbnail() throws {
        let data = encode(makeImage(width: 400, height: 200), as: .png)
        let thumbnail = try #require(TaskImage.thumbnail(data, maxPixelSize: 100))
        #expect(thumbnail.width == 100)
        #expect(thumbnail.height == 50)
    }

    @Test("a normalised crop maps onto pixels with a top-left origin (no flip)")
    func croppedOrientation() throws {
        let image = makeImage(width: 100, height: 50)
        let top = try #require(TaskImage.cropped(image, to: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(top.width == 50 && top.height == 25)
        #expect(averageColor(top) == (255, 0))       // the top half is the red one

        let bottom = try #require(TaskImage.cropped(image, to: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)))
        #expect(averageColor(bottom) == (0, 255))
    }

    @Test("dragging a corner moves only that corner, clamped to the image")
    func draggingCorner() {
        let crop = TaskImage.dragging(TaskImage.fullCrop, corner: .topLeading, by: CGSize(width: 0.25, height: 0.5))
        #expect(crop == CGRect(x: 0.25, y: 0.5, width: 0.75, height: 0.5))   // bottom-trailing stays put

        let outward = TaskImage.dragging(crop, corner: .topLeading, by: CGSize(width: -1, height: -1))
        #expect(outward == TaskImage.fullCrop)
    }

    @Test("a corner can't collapse the crop below the minimum side")
    func draggingMinimumSize() {
        let crop = TaskImage.dragging(TaskImage.fullCrop, corner: .bottomTrailing, by: CGSize(width: -2, height: -2))
        #expect(crop == CGRect(x: 0, y: 0, width: TaskImage.minCropSide, height: TaskImage.minCropSide))
    }

    @Test("sliding keeps the crop's size and keeps it inside the image")
    func movingCrop() {
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        #expect(TaskImage.moving(crop, by: CGSize(width: 0.125, height: -0.125))
            == CGRect(x: 0.375, y: 0.125, width: 0.5, height: 0.5))
        #expect(TaskImage.moving(crop, by: CGSize(width: 5, height: -5)) == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    @Test("the preview file is the cropped image as PNG — the stored bytes themselves when uncropped")
    func previewFile() throws {
        let png = encode(makeImage(width: 100, height: 50), as: .png)

        let full = try #require(TaskImage.writePreviewFile(png, crop: TaskImage.fullCrop))
        #expect(try Data(contentsOf: full) == png)

        let url = try #require(TaskImage.writePreviewFile(png, crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(url != full)   // a fresh file each time, so Quick Look never shows a stale crop
        let image = try #require(TaskImage.thumbnail(try Data(contentsOf: url), maxPixelSize: 1000))
        #expect(image.width == 50 && image.height == 25)
    }
}

// MARK: - Paste routing

@MainActor
@Suite("Pasting images")
struct PasteImageTests {
    /// A private, throwaway pasteboard, so the tests never touch the user's clipboard.
    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tic.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try body(pasteboard)
    }

    @Test("image data on its own pastes as an image")
    func imageData() throws {
        try withPasteboard { pasteboard in
            pasteboard.setData(encode(makeImage(), as: .tiff), forType: .tiff)
            #expect(pasteboard.hasPastableImage)
            let data = try #require(pasteboard.pastableImageData())
            #expect(imageType(data) == UTType.png.identifier)
        }
    }

    @Test("image data with plain text alongside pastes as text")
    func textWins() {
        withPasteboard { pasteboard in
            pasteboard.setData(encode(makeImage(), as: .png), forType: .png)
            pasteboard.setString("hello", forType: .string)
            #expect(!pasteboard.hasPastableImage)
            #expect(pasteboard.pastableImageData() == nil)
        }
    }

    @Test("an image file pastes as an image even with its name on the clipboard as text")
    func imageFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tic-\(UUID().uuidString).png")
        try encode(makeImage(), as: .png).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try withPasteboard { pasteboard in
            pasteboard.writeObjects([url as NSURL, url.lastPathComponent as NSString])
            #expect(pasteboard.hasPastableImage)
            let data = try #require(pasteboard.pastableImageData())
            #expect(!data.isEmpty)
        }
    }

    @Test("a non-image file pastes as text")
    func nonImageFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tic-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        withPasteboard { pasteboard in
            pasteboard.writeObjects([url as NSURL])
            #expect(!pasteboard.hasPastableImage)
            #expect(pasteboard.pastableImageData() == nil)
        }
    }

    @Test("with nothing being edited, Paste travels past the SwiftUI hosting view to the note panel")
    func pasteReachesPanel() {
        _ = NSApplication.shared
        let panel = NotePanel(note: Note(), content: AnyView(Color.clear))
        var responder: NSResponder? = panel.contentView
        while let current = responder, !current.responds(to: #selector(NSText.paste(_:))) {
            responder = current.nextResponder
        }
        #expect(responder === panel)
    }
}

// MARK: - Storage

@Suite("Task images in the database")
struct TaskImageDatabaseTests {
    private func makeTaskWithImage() async throws -> (AppDatabase, Note, TaskItem, Data) {
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        try await db.insert(note)
        let task = TaskItem(noteId: note.id)
        let png = encode(makeImage(), as: .png)
        try await db.insertTask(task, imageData: png)
        return (db, note, task, png)
    }

    @Test("a task inserted with an image stores the bytes and starts uncropped")
    func insertWithImage() async throws {
        let (db, note, task, png) = try await makeTaskWithImage()
        #expect(try await db.taskImageData(taskId: task.id) == png)
        #expect(try await firstCrops(db, note.id) == [task.id: TaskImage.fullCrop])
    }

    @Test("a whole-record task text commit leaves the image and its crop untouched")
    func textCommitKeepsImage() async throws {
        let (db, note, task, png) = try await makeTaskWithImage()
        let crop = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        try await db.updateTaskImageCrop(taskId: task.id, crop: crop)
        var captioned = task
        captioned.text = "caption"
        try await db.update(captioned)
        #expect(try await db.taskImageData(taskId: task.id) == png)
        #expect(try await firstCrops(db, note.id) == [task.id: crop])
    }

    @Test("replacing an image resets its crop")
    func replaceResetsCrop() async throws {
        let (db, note, task, _) = try await makeTaskWithImage()
        try await db.updateTaskImageCrop(taskId: task.id, crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let replacement = encode(makeImage(width: 10, height: 10), as: .png)
        try await db.setTaskImage(taskId: task.id, data: replacement)
        #expect(try await db.taskImageData(taskId: task.id) == replacement)
        #expect(try await firstCrops(db, note.id) == [task.id: TaskImage.fullCrop])
    }

    @Test("removing an image keeps its task")
    func deleteImageKeepsTask() async throws {
        let (db, note, task, _) = try await makeTaskWithImage()
        try await db.deleteTaskImage(taskId: task.id)
        #expect(try await db.taskImageData(taskId: task.id) == nil)
        #expect(try await db.tasks(noteId: note.id).map(\.id) == [task.id])
    }

    @Test("deleting a note cascades to its task images")
    func cascade() async throws {
        let (db, note, task, _) = try await makeTaskWithImage()
        try await db.deleteNote(id: note.id)
        #expect(try await db.taskImageData(taskId: task.id) == nil)
    }
}

// MARK: - Controller

@MainActor
@Suite("NoteController images")
struct NoteControllerImageTests {
    private func makeController() async throws -> NoteController {
        let db = try AppDatabase.makeInMemory()
        let note = Note()
        try await db.insert(note)
        return NoteController(note: note, database: db)
    }

    @Test("a pasted image-only task is kept when its blank text is committed")
    func imageOnlyTaskSurvivesBlankCommit() async throws {
        let c = try await makeController()
        c.addTask("", imageData: encode(makeImage(), as: .png))
        let task = try #require(c.tasks.first)
        #expect(c.imageCrops[task.id] == TaskImage.fullCrop)

        c.commitText(task, "   ")
        #expect(c.tasks.map(\.id) == [task.id])
    }

    @Test("a blank task with no image is still never added")
    func blankWithoutImageIgnored() async throws {
        let c = try await makeController()
        c.addTask("   ")
        #expect(c.tasks.isEmpty)
    }

    @Test("pasting onto a blank new row saves it from the blank-row cleanup")
    func attachKeepsBlankRow() async throws {
        let c = try await makeController()
        c.addTask("Heading")
        let heading = try #require(c.tasks.first)
        let id = try #require(c.addSubtask(under: heading))
        let row = try #require(c.tasks.first { $0.id == id })

        c.attachImage(encode(makeImage(), as: .png), to: row)
        c.commitText(row, "")
        #expect(c.tasks.contains { $0.id == id })
    }

    @Test("setCrop changes an image's crop; tasks without an image are ignored")
    func setCrop() async throws {
        let c = try await makeController()
        c.addTask("", imageData: encode(makeImage(), as: .png))
        c.addTask("plain")
        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        c.setCrop(crop, for: c.tasks[0])
        c.setCrop(crop, for: c.tasks[1])
        #expect(c.imageCrops == [c.tasks[0].id: crop])
    }

    @Test("removing the image of an image-only task removes the task; a captioned task keeps its text")
    func removeImage() async throws {
        let c = try await makeController()
        let png = encode(makeImage(), as: .png)
        c.addTask("", imageData: png)
        c.addTask("Captioned", imageData: png)
        let (imageOnly, captioned) = (c.tasks[0], c.tasks[1])

        c.removeImage(from: imageOnly)
        c.removeImage(from: captioned)
        #expect(c.tasks.map(\.text) == ["Captioned"])
        #expect(c.imageCrops.isEmpty)
    }
}
