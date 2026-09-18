import CoreGraphics
import Foundation
import MCP

/// The MCP tool surface: everything a person can do to notes and tasks, over `AppDatabase`. Pure
/// data + three window pokes (`WindowActions`); the existing GRDB observers carry every write into
/// the open panels, so "live update" needs nothing here. Reuses `TaskOutline` for every structural
/// rule (level clamp, completion cascade, normalise) so tools and the UI can never diverge.
struct MCPTools: Sendable {
    let database: AppDatabase
    let window: WindowActions

    /// The only reach into AppKit: bring a note's panel up, hide it, or move it. Set by `AppModel`
    /// so this stays AppKit-free (mirrors how `NoteController` uses closures).
    struct WindowActions: Sendable {
        var open: @Sendable (UUID) async -> Void = { _ in }
        var close: @Sendable (UUID) async -> Void = { _ in }
        var setFrame: @Sendable (UUID, CGRect) async -> Void = { _, _ in }
    }

    private struct ToolError: Error { let message: String; init(_ m: String) { message = m } }

    private static let maxTasksPerCall = 200
    private static let maxTextLength = 20_000
    private static let maxImageBytes = 10 * 1024 * 1024

    // MARK: - Dispatch

    func call(_ name: String, _ arguments: [String: Value]?) async -> CallTool.Result {
        let args = Args(arguments)
        do {
            let value: Value
            switch name {
            case "list_notes":      value = try await listNotes()
            case "get_note":        value = try await getNote(args)
            case "create_note":     value = try await createNote(args)
            case "update_note":     value = try await updateNote(args)
            case "move_note":       value = try await moveNote(args)
            case "delete_note":     value = try await deleteNote(args)
            case "add_tasks":       value = try await addTasks(args)
            case "update_task":     value = try await updateTask(args)
            case "move_task":       value = try await moveTask(args)
            case "delete_tasks":    value = try await deleteTasks(args)
            case "clear_completed": value = try await clearCompleted(args)
            case "set_task_image":  value = try await setTaskImage(args)
            case "crop_task_image": value = try await cropTaskImage(args)
            case "remove_task_image": value = try await removeTaskImage(args)
            default: throw ToolError("Unknown tool: \(name)")
            }
            return CallTool.Result(content: [.text(json(value))], isError: false)
        } catch let error as ToolError {
            return CallTool.Result(content: [.text(error.message)], isError: true)
        } catch {
            return CallTool.Result(content: [.text("Tic error: \(error.localizedDescription)")], isError: true)
        }
    }

    // MARK: - Tool definitions

    func definitions() -> [Tool] {
        let readOnly = Tool.Annotations(readOnlyHint: true)
        let destructive = Tool.Annotations(destructiveHint: true)

        return [
            Tool(name: "list_notes",
                 description: "List every Tic note (sticky) with its id, title, colour, and whether it's on screen. Call get_note for a note's tasks.",
                 inputSchema: object([:]), annotations: readOnly),

            Tool(name: "get_note",
                 description: "Get one note in full: its properties and its tasks (each with id, text, indent level 0-2, and done state).",
                 inputSchema: object(["note_id": prop("string", "The note's id")], required: ["note_id"]),
                 annotations: readOnly),

            Tool(name: "create_note",
                 description: "Create a new sticky note and open it on the desktop. Optionally seed it with tasks. Tasks build an outline: give each a level (0 top, 1-2 nested) to make sub-items.",
                 inputSchema: object([
                    "title": prop("string", "Note title (optional; auto-named if omitted)"),
                    "color": enumProp(NoteColor.allCases.map(\.rawValue), "Note colour"),
                    "material": enumProp(["solid", "glass"], "Background style"),
                    "tasks": taskArraySchema,
                    "float_on_top": prop("boolean", "Keep the note above other windows"),
                    "show_on_all_spaces": prop("boolean", "Show the note on every desktop/Space"),
                    "collapsed": prop("boolean", "Start rolled up to just the title bar"),
                 ])),

            Tool(name: "update_note",
                 description: "Change a note's title, colour, material, window flags, or completed-task display. Set open=true to bring it to the front, open=false to hide it. Only the fields you pass change.",
                 inputSchema: object([
                    "note_id": prop("string", "The note's id"),
                    "title": prop("string", "New title"),
                    "color": enumProp(NoteColor.allCases.map(\.rawValue), "New colour"),
                    "material": enumProp(["solid", "glass"], "New background style"),
                    "float_on_top": prop("boolean", "Keep above other windows"),
                    "show_on_all_spaces": prop("boolean", "Show on every Space"),
                    "collapsed": prop("boolean", "Roll up to the title bar"),
                    "hide_completed": prop("boolean", "Hide checked-off tasks"),
                    "move_completed_to_bottom": prop("boolean", "Sink checked tasks to the bottom"),
                    "open": prop("boolean", "true brings the note to front, false hides it"),
                 ], required: ["note_id"])),

            Tool(name: "move_note",
                 description: "Move or resize a note's window. Coordinates are global desktop points (origin bottom-left), matching how Stickies stores them.",
                 inputSchema: object([
                    "note_id": prop("string", "The note's id"),
                    "x": prop("number", "Left edge"), "y": prop("number", "Bottom edge"),
                    "width": prop("number", "Width"), "height": prop("number", "Height"),
                 ], required: ["note_id"])),

            Tool(name: "delete_note",
                 description: "Permanently delete a note and all its tasks. Cannot be undone.",
                 inputSchema: object(["note_id": prop("string", "The note's id")], required: ["note_id"]),
                 annotations: destructive),

            Tool(name: "add_tasks",
                 description: "Append tasks to a note. Each task is a string, or an object {text, level} where level 0-2 sets nesting to build sub-items. Levels are clamped to a valid outline.",
                 inputSchema: object([
                    "note_id": prop("string", "The note's id"),
                    "tasks": taskArraySchema,
                 ], required: ["note_id", "tasks"])),

            Tool(name: "update_task",
                 description: "Edit a task's text and/or tick it done or not. Ticking a parent ticks its whole subtree; finishing the last child auto-ticks the parent (and reopening a child reopens its parents).",
                 inputSchema: object([
                    "task_id": prop("string", "The task's id"),
                    "text": prop("string", "New text (must not be blank)"),
                    "done": prop("boolean", "Mark done or not done"),
                 ], required: ["task_id"])),

            Tool(name: "move_task",
                 description: "Reorder a task (and its subtree) and/or re-nest it. to_index is where it lands among the note's tasks; level 0-2 sets its new depth. Tick states are preserved.",
                 inputSchema: object([
                    "task_id": prop("string", "The task's id"),
                    "to_index": prop("integer", "Target position among the note's tasks (0-based)"),
                    "level": prop("integer", "New indent level 0-2"),
                 ], required: ["task_id"])),

            Tool(name: "delete_tasks",
                 description: "Delete one or more tasks by id. Their sub-tasks are kept and re-levelled. Cannot be undone.",
                 inputSchema: object(["task_ids": .object(["type": "array", "items": prop("string", "A task id"), "description": "Task ids to delete"])], required: ["task_ids"]),
                 annotations: destructive),

            Tool(name: "clear_completed",
                 description: "Remove every checked-off task in a note. Cannot be undone.",
                 inputSchema: object(["note_id": prop("string", "The note's id")], required: ["note_id"]),
                 annotations: destructive),

            Tool(name: "set_task_image",
                 description: "Attach an image to a task (replacing any it has). Provide the image as base64 PNG or JPEG (a data: URL is also accepted). Max 10 MB.",
                 inputSchema: object([
                    "task_id": prop("string", "The task's id"),
                    "data": prop("string", "Base64-encoded PNG or JPEG"),
                 ], required: ["task_id", "data"])),

            Tool(name: "crop_task_image",
                 description: "Crop a task's image. The rect is fractions 0-1 of the image with a top-left origin; it's clamped to stay in bounds. The original is kept, so cropping is reversible.",
                 inputSchema: object([
                    "task_id": prop("string", "The task's id"),
                    "x": prop("number", "Left, 0-1"), "y": prop("number", "Top, 0-1"),
                    "width": prop("number", "Width, 0-1"), "height": prop("number", "Height, 0-1"),
                 ], required: ["task_id", "x", "y", "width", "height"])),

            Tool(name: "remove_task_image",
                 description: "Remove a task's image. If the task has no text, the task itself is removed too (an image-only task).",
                 inputSchema: object(["task_id": prop("string", "The task's id")], required: ["task_id"]),
                 annotations: destructive),
        ]
    }

    private func object(_ props: [String: Value], required: [String] = []) -> Value {
        var o: [String: Value] = ["type": "object"]
        if !props.isEmpty { o["properties"] = .object(props) }
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    private func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private func enumProp(_ cases: [String], _ description: String) -> Value {
        .object(["type": "string", "enum": .array(cases.map { .string($0) }), "description": .string(description)])
    }

    private var taskArraySchema: Value {
        .object([
            "type": "array",
            "description": "Tasks — each a string, or {text, level} where level is 0 (top), 1, or 2.",
            "items": .object(["type": .array(["string", "object"])]),
        ])
    }

    // MARK: - Note tools

    private func listNotes() async throws -> Value {
        let notes = try await database.allNotes()
        return .array(notes.map { n in
            .object([
                "id": .string(n.id.uuidString),
                "title": .string(n.title),
                "color": .string(n.color.rawValue),
                "is_open": .bool(n.isOpen),
            ])
        })
    }

    private func getNote(_ args: Args) async throws -> Value {
        let id = try args.uuid("note_id")
        let note = try await note(id)
        let tasks = try await database.tasks(noteId: id)
        let imageIds = try await database.taskImageIds(noteId: id)
        return noteValue(note, tasks: tasks, imageIds: imageIds)
    }

    private func createNote(_ args: Args) async throws -> Value {
        let stored = try await database.insertNewNote(Note(
            title: (args.string("title") ?? "").trimmed.capped,
            color: try args.string("color").map(color) ?? .yellow,
            material: try args.string("material").map(material) ?? .solid,
            floatOnTop: args.bool("float_on_top") ?? false,
            showOnAllSpaces: args.bool("show_on_all_spaces") ?? false,
            isCollapsed: args.bool("collapsed") ?? false
        ))

        if let frame = args.frame() {
            try await database.updateNoteFrame(
                id: stored.id, x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        } else {
            // The cascade `NoteWindowManager.newNote` uses, so an agent's note doesn't stack dead-on.
            let step = Double(stored.sortIndex % 8) * 28
            try await database.updateNoteFrame(
                id: stored.id, x: 180 + step, y: 320 - step, width: stored.frameW, height: stored.frameH)
        }

        if let items = args.array("tasks") {
            for task in try buildTasks(items, noteId: stored.id, existing: []) {
                try await database.insertTask(task)
            }
        }

        await window.open(stored.id)
        let tasks = try await database.tasks(noteId: stored.id)
        return noteValue(stored, tasks: tasks)
    }

    private func updateNote(_ args: Args) async throws -> Value {
        let id = try args.uuid("note_id")
        let current = try await note(id)

        if let title = args.string("title") {
            try await database.updateNoteTitle(id: id, title: title.trimmed.capped)
        }

        let newColor = try args.string("color").map(color) ?? current.color
        let newMaterial = try args.string("material").map(material) ?? current.material
        if newColor != current.color || newMaterial != current.material {
            try await database.updateNoteAppearance(id: id, color: newColor, material: newMaterial)
        }

        let float = args.bool("float_on_top") ?? current.floatOnTop
        let allSpaces = args.bool("show_on_all_spaces") ?? current.showOnAllSpaces
        let collapsed = args.bool("collapsed") ?? current.isCollapsed
        if float != current.floatOnTop || allSpaces != current.showOnAllSpaces || collapsed != current.isCollapsed {
            try await database.updateNoteFlags(id: id, floatOnTop: float, showOnAllSpaces: allSpaces, isCollapsed: collapsed)
        }

        let hide = args.bool("hide_completed") ?? current.hideCompleted
        let move = args.bool("move_completed_to_bottom") ?? current.moveCompletedToBottom
        if hide != current.hideCompleted || move != current.moveCompletedToBottom {
            try await database.updateNoteListOptions(id: id, hideCompleted: hide, moveCompletedToBottom: move)
        }

        if let open = args.bool("open") {
            if open { await window.open(id) } else { await window.close(id) }
        }

        return noteValue(try await note(id), tasks: nil)
    }

    private func moveNote(_ args: Args) async throws -> Value {
        let id = try args.uuid("note_id")
        let n = try await note(id)
        let rect = CGRect(
            x: args.double("x") ?? n.frameX,
            y: args.double("y") ?? n.frameY,
            width: max(120, args.double("width") ?? n.frameW),
            height: max(80, args.double("height") ?? n.frameH)
        )
        await window.setFrame(id, rect)
        return .object(["frame": frameValue(rect)])
    }

    private func deleteNote(_ args: Args) async throws -> Value {
        let id = try args.uuid("note_id")
        _ = try await note(id)
        await window.close(id)
        try await database.deleteNote(id: id)   // tasks + images cascade
        return .object(["deleted": .string(id.uuidString)])
    }

    // MARK: - Task tools

    private func addTasks(_ args: Args) async throws -> Value {
        let id = try args.uuid("note_id")
        _ = try await note(id)
        guard let items = args.array("tasks"), !items.isEmpty else { throw ToolError("'tasks' is required") }
        let existing = try await database.tasks(noteId: id)
        let built = try buildTasks(items, noteId: id, existing: existing)
        guard !built.isEmpty else { throw ToolError("No non-empty tasks given") }
        for task in built { try await database.insertTask(task) }
        return .object(["added": .int(built.count), "note_id": .string(id.uuidString)])
    }

    private func updateTask(_ args: Args) async throws -> Value {
        let id = try args.uuid("task_id")
        guard let task = try await database.task(id: id) else { throw ToolError("No task with id \(id.uuidString)") }
        var changed: [String] = []

        if let text = args.string("text") {
            let trimmed = text.trimmed
            guard !trimmed.isEmpty else { throw ToolError("Task text can't be blank — use delete_tasks to remove it") }
            if trimmed != task.text {
                var updated = task
                updated.text = trimmed.capped
                try await database.update(updated)
                changed.append("text")
            }
        }

        if let done = args.bool("done"), done != task.isDone {
            // Route completion through the same cascade a checkbox uses (ticks the subtree, bubbles up).
            let all = try await database.tasks(noteId: task.noteId)
            let toggled = TaskOutline.applyingToggle(all, toggling: id, now: Date())
            try await database.updateTaskCompletion(TaskOutline.completionChanges(from: all, to: toggled))
            changed.append("done")
        }

        return .object(["task_id": .string(id.uuidString), "changed": .array(changed.map { .string($0) })])
    }

    private func moveTask(_ args: Args) async throws -> Value {
        let id = try args.uuid("task_id")
        guard let task = try await database.task(id: id) else { throw ToolError("No task with id \(id.uuidString)") }
        let all = try await database.tasks(noteId: task.noteId)
        guard let currentIndex = all.firstIndex(where: { $0.id == id }) else { throw ToolError("Task not in its note") }

        let toIndex = min(max(args.int("to_index") ?? currentIndex, 0), all.count)
        let level = args.int("level").map { min(max($0, 0), TaskItem.maxIndentLevel) }
        let reordered = TaskOutline.movingSubtree(all, id: id, toInsertionIndex: toIndex, targetLevel: level)
        guard reordered != all else { return .object(["task_id": .string(id.uuidString), "moved": .bool(false)]) }

        let normalized = TaskOutline.normalizedLevels(reordered)
        let levels = TaskOutline.indentLevelChanges(from: all, to: normalized).map { TaskLevelUpdate(id: $0.id, level: $0.level) }
        try await database.applyStructuralUpdate(deleteIds: [], reorder: normalized, levels: levels)
        return .object(["task_id": .string(id.uuidString), "moved": .bool(true)])
    }

    private func deleteTasks(_ args: Args) async throws -> Value {
        let ids = try args.uuidArray("task_ids")
        guard let first = try await database.task(id: ids[0]) else { throw ToolError("No task with id \(ids[0].uuidString)") }
        let all = try await database.tasks(noteId: first.noteId)
        let idSet = Set(ids)
        let deleteIds = all.filter { idSet.contains($0.id) }.map(\.id)
        guard !deleteIds.isEmpty else { throw ToolError("None of those ids are in the note") }
        // Deleting keeps a row's subtasks (like the UI); survivors are renormalised so nothing orphans.
        let survivors = TaskOutline.normalizedLevels(all.filter { !idSet.contains($0.id) })
        let levels = TaskOutline.indentLevelChanges(from: all, to: survivors).map { TaskLevelUpdate(id: $0.id, level: $0.level) }
        try await database.applyStructuralUpdate(deleteIds: deleteIds, reorder: survivors, levels: levels)
        return .object(["deleted": .int(deleteIds.count)])
    }

    private func clearCompleted(_ args: Args) async throws -> Value {
        let id = try args.uuid("note_id")
        let all = try await database.tasks(noteId: id)
        let doneIds = all.filter(\.isDone).map(\.id)
        guard !doneIds.isEmpty else { return .object(["cleared": .int(0)]) }
        let survivors = TaskOutline.normalizedLevels(all.filter { !$0.isDone })
        let levels = TaskOutline.indentLevelChanges(from: all, to: survivors).map { TaskLevelUpdate(id: $0.id, level: $0.level) }
        try await database.applyStructuralUpdate(deleteIds: doneIds, reorder: survivors, levels: levels)
        return .object(["cleared": .int(doneIds.count)])
    }

    // MARK: - Image tools

    private func setTaskImage(_ args: Args) async throws -> Value {
        let id = try args.uuid("task_id")
        guard try await database.task(id: id) != nil else { throw ToolError("No task with id \(id.uuidString)") }
        guard let encoded = args.string("data") else { throw ToolError("'data' (base64 PNG/JPEG) is required") }
        // Accept a bare base64 string or a data: URL.
        let base64 = encoded.hasPrefix("data:") ? String(encoded.drop(while: { $0 != "," }).dropFirst()) : encoded
        guard let raw = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw ToolError("'data' is not valid base64")
        }
        guard raw.count <= Self.maxImageBytes else { throw ToolError("Image too large (max 10 MB)") }
        guard let normalized = TaskImage.normalizedData(raw) else { throw ToolError("'data' isn't a decodable image (PNG or JPEG)") }
        try await database.setTaskImage(taskId: id, data: normalized)   // replacing resets the crop to full
        return .object(["task_id": .string(id.uuidString), "bytes": .int(normalized.count)])
    }

    private func cropTaskImage(_ args: Args) async throws -> Value {
        let id = try args.uuid("task_id")
        guard try await database.hasImage(taskId: id) else { throw ToolError("Task \(id.uuidString) has no image to crop") }
        guard let x = args.double("x"), let y = args.double("y"),
              let w = args.double("width"), let h = args.double("height") else {
            throw ToolError("Crop needs x, y, width, height as fractions 0…1 with a top-left origin")
        }
        // Clamp to an in-bounds rect no smaller than the minimum side.
        let cw = min(max(w, TaskImage.minCropSide), 1)
        let ch = min(max(h, TaskImage.minCropSide), 1)
        let cx = min(max(x, 0), 1 - cw)
        let cy = min(max(y, 0), 1 - ch)
        let crop = CGRect(x: cx, y: cy, width: cw, height: ch)
        try await database.updateTaskImageCrop(taskId: id, crop: crop)
        return .object(["task_id": .string(id.uuidString), "crop": frameValue(crop)])
    }

    private func removeTaskImage(_ args: Args) async throws -> Value {
        let id = try args.uuid("task_id")
        guard let task = try await database.task(id: id) else { throw ToolError("No task with id \(id.uuidString)") }
        guard try await database.hasImage(taskId: id) else { throw ToolError("Task has no image") }
        if task.text.trimmed.isEmpty {
            // An image-only task has nothing left once the image goes — delete the task (image cascades),
            // exactly like the UI's remove-image.
            let all = try await database.tasks(noteId: task.noteId)
            let survivors = TaskOutline.normalizedLevels(all.filter { $0.id != id })
            let levels = TaskOutline.indentLevelChanges(from: all, to: survivors).map { TaskLevelUpdate(id: $0.id, level: $0.level) }
            try await database.applyStructuralUpdate(deleteIds: [id], reorder: survivors, levels: levels)
            return .object(["removed_image": .bool(true), "deleted_task": .bool(true)])
        }
        try await database.deleteTaskImage(taskId: id)
        return .object(["removed_image": .bool(true), "deleted_task": .bool(false)])
    }

    // MARK: - Helpers

    private func note(_ id: UUID) async throws -> Note {
        guard let note = try await database.note(id: id) else { throw ToolError("No note with id \(id.uuidString)") }
        return note
    }

    /// Parses `tasks` (each a string, or `{text, level}`) into new `TaskItem`s appended after
    /// `existing`, with levels clamped and normalised so the appended block is always a valid outline.
    private func buildTasks(_ items: [Value], noteId: UUID, existing: [TaskItem]) throws -> [TaskItem] {
        guard items.count <= Self.maxTasksPerCall else { throw ToolError("Too many tasks in one call (max \(Self.maxTasksPerCall))") }
        var built: [TaskItem] = []
        for item in items {
            let text: String
            let level: Int
            if let s = item.stringValue { text = s.trimmed; level = 0 }
            else if let o = item.objectValue {
                text = (o["text"]?.stringValue ?? "").trimmed
                level = (o["level"].flatMap { $0.intValue ?? $0.doubleValue.map(Int.init) }) ?? 0
            } else { throw ToolError("Each task must be a string or an object {text, level}") }
            guard !text.isEmpty else { continue }
            built.append(TaskItem(noteId: noteId, text: text.capped, indentLevel: min(max(level, 0), TaskItem.maxIndentLevel)))
        }
        guard !built.isEmpty else { return [] }
        let normalized = TaskOutline.normalizedLevels(existing + built)
        return Array(normalized.suffix(built.count))
    }

    private func color(_ raw: String) throws -> NoteColor {
        guard let c = NoteColor(rawValue: raw.lowercased()) else {
            throw ToolError("Unknown color '\(raw)'. Options: \(NoteColor.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return c
    }

    private func material(_ raw: String) throws -> NoteMaterial {
        guard let m = NoteMaterial(rawValue: raw.lowercased()) else {
            throw ToolError("Unknown material '\(raw)'. Options: solid, glass")
        }
        return m
    }

    private func noteValue(_ n: Note, tasks: [TaskItem]?, imageIds: Set<UUID> = []) -> Value {
        var o: [String: Value] = [
            "id": .string(n.id.uuidString),
            "title": .string(n.title),
            "color": .string(n.color.rawValue),
            "material": .string(n.material.rawValue),
            "is_open": .bool(n.isOpen),
            "float_on_top": .bool(n.floatOnTop),
            "show_on_all_spaces": .bool(n.showOnAllSpaces),
            "collapsed": .bool(n.isCollapsed),
            "hide_completed": .bool(n.hideCompleted),
            "move_completed_to_bottom": .bool(n.moveCompletedToBottom),
            "frame": frameValue(CGRect(x: n.frameX, y: n.frameY, width: n.frameW, height: n.frameH)),
        ]
        if let tasks {
            o["tasks"] = .array(tasks.map { t in
                .object([
                    "id": .string(t.id.uuidString),
                    "text": .string(t.text),
                    "level": .int(t.indentLevel),
                    "done": .bool(t.isDone),
                    "has_image": .bool(imageIds.contains(t.id)),
                ])
            })
        }
        return .object(o)
    }

    private func frameValue(_ r: CGRect) -> Value {
        .object(["x": .double(r.origin.x), "y": .double(r.origin.y), "width": .double(r.width), "height": .double(r.height)])
    }

    private func json(_ value: Value) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Argument access

    private struct Args {
        let raw: [String: Value]
        init(_ a: [String: Value]?) { raw = a ?? [:] }

        func string(_ k: String) -> String? { raw[k]?.stringValue }
        func bool(_ k: String) -> Bool? { raw[k]?.boolValue }
        func array(_ k: String) -> [Value]? { raw[k]?.arrayValue }
        func int(_ k: String) -> Int? { raw[k].flatMap { $0.intValue ?? $0.doubleValue.map(Int.init) } }
        func double(_ k: String) -> Double? { raw[k].flatMap { $0.doubleValue ?? $0.intValue.map(Double.init) } }

        func uuid(_ k: String) throws -> UUID {
            guard let s = raw[k]?.stringValue else { throw ToolError("Missing '\(k)'") }
            guard let id = UUID(uuidString: s) else { throw ToolError("'\(k)' is not a valid id: \(s)") }
            return id
        }

        func uuidArray(_ k: String) throws -> [UUID] {
            guard let arr = raw[k]?.arrayValue, !arr.isEmpty else { throw ToolError("'\(k)' is required") }
            return try arr.map { v in
                guard let s = v.stringValue, let id = UUID(uuidString: s) else { throw ToolError("'\(k)' has an invalid id") }
                return id
            }
        }

        func frame() -> CGRect? {
            guard let x = double("x"), let y = double("y") else { return nil }
            return CGRect(x: x, y: y, width: double("width") ?? 280, height: double("height") ?? 360)
        }
    }

}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var capped: String { count > 20_000 ? String(prefix(20_000)) : self }
}
