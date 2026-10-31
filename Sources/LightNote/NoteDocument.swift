import AppKit
import SwiftUI
import OSLog

enum InkTool {
    case pen, eraser, selection, laser, ellipse, rectangle, arrow
    var title: String {
        switch self { case .pen: "볼펜"; case .eraser: "획 지우개"; case .selection: "사각형 선택"; case .laser: "레이저"; case .ellipse: "원 / 타원"; case .rectangle: "사각형"; case .arrow: "화살표" }
    }
    var symbol: String {
        switch self { case .pen: "pencil.tip"; case .eraser: "eraser"; case .selection: "selection.pin.in.out"; case .laser: "dot.scope"; case .ellipse: "circle"; case .rectangle: "rectangle"; case .arrow: "arrow.up.right" }
    }
    var hint: String {
        switch self {
        case .pen: "일정한 굵기"
        case .eraser: "닿은 획 전체 삭제"
        case .selection: "영역 선택 후 안쪽을 드래그하여 이동"
        case .arrow: "드래그한 방향으로 화살표 그리기"
        case .ellipse, .rectangle: "드래그하여 그리기 · ⌘ 정원 / 정사각형"
        case .laser: "누르는 동안 유지 · 떼면 1초 후 2초간 서서히 사라짐"
        }
    }
}

@MainActor
final class NoteState: NSObject, ObservableObject {
    static let eraserRadius: CGFloat = 6
    var refreshCursor: (() -> Void)?
    var invalidateStrokeCache: ((Set<UUID>) -> Void)?
    @Published var showShortcuts = false
    @Published var tool: InkTool = .pen
    func selectTool(_ tool: InkTool) {
        finishInput?()
        self.tool = tool
        refreshCursor?()
    }
    static var colorPresets: [(key: String, name: String, color: InkColor)] { AppPreferences.shared.colorPresets }
    @Published var color: InkColor = .black
    static let penWidths: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0]
    @Published var width: Double = 1.5
    func adjustPenWidth(increase: Bool) {
        if increase {
            width = Self.penWidths.first(where: { $0 > width }) ?? Self.penWidths.last!
        } else {
            width = Self.penWidths.last(where: { $0 < width }) ?? Self.penWidths.first!
        }
    }
    @Published var zoom: CGFloat = 1
    var resetZoom: (() -> Void)?
    @Published var revision = 0
    @Published var strokeCount = 0
    @Published var canUndo = false
    @Published var canRedo = false
    // Mutations occur on the main thread; input samples never trigger SwiftUI updates.
    var note = NoteFile()
    var finishInput: (() -> Void)?
    var invalidate: ((CGRect?) -> Void)?
    weak var document: NoteDocument?
    var refreshAppearance: (() -> Void)?
    override init() {
        super.init()
        let preferences = AppPreferences.shared
        color = preferences.penColor; width = preferences.penWidth; note.paperStyle = preferences.defaultPaper
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged(_:)),
            name: AppPreferences.changed, object: preferences)
    }
    @objc private func preferencesChanged(_ notification: Notification) {
        let kind = notification.userInfo?["kind"] as? String
        if kind == "pen" { color = AppPreferences.shared.penColor; width = AppPreferences.shared.penWidth }
        if kind == "paper" { refreshAppearance?() }
    }
    func refresh() {
        strokeCount = note.strokes.count
        canUndo = document?.undoManager?.canUndo ?? false
        canRedo = document?.undoManager?.canRedo ?? false
        revision &+= 1
    }
}

@objc(NoteDocument)
final class NoteDocument: NSDocument {
    let state = NoteState()
    private let log = Logger(subsystem: "com.lightnote.app", category: "Document")
    override init() {
        super.init()
        state.document = self
        hasUndoManager = true
    }
    override class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func makeWindowControllers() {
        if !CommandLine.arguments.contains("--self-test"), fileURL == nil {
            do { try persistNow() } catch { NSApp.presentError(error) }
        }
        let root = EditorView(state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isRestorable = false
        NotificationCenter.default.addObserver(self, selector: #selector(rememberLastDocument),
            name: NSWindow.didBecomeKeyNotification, object: window)
        window.minSize = NSSize(width: 740, height: 480)
        window.contentView = NSHostingView(rootView: root)
        window.setFrameAutosaveName("LightNoteEditor")
        window.center()
        addWindowController(NoteWindowController(window: window))
    }

    @objc private func rememberLastDocument() {
        guard !CommandLine.arguments.contains("--self-test"), let fileURL else { return }
        guard windowControllers.contains(where: { $0.window?.isKeyWindow == true }) else { return }
        UserDefaults.standard.set(fileURL.path, forKey: LightNoteDocumentController.lastDocumentKey)
    }

    /// Assign a real file before the first close; use NSDocument's safe replacement writer.
    func persistNow(directory: URL? = nil) throws {
        state.finishInput?()
        let type = fileType ?? "com.lightnote.note"
        let destination: URL
        if let fileURL { destination = fileURL }
        else {
            let folder = directory ?? LightNoteDocumentController.notesDirectory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var number = 1
            var candidate = folder.appendingPathComponent("새 노트.lightnote")
            while FileManager.default.fileExists(atPath: candidate.path) {
                number += 1
                candidate = folder.appendingPathComponent("새 노트 \(number).lightnote")
            }
            destination = candidate
        }
        try writeSafely(to: destination, ofType: type, for: .saveOperation)
        fileURL = destination
        fileType = type
        isDraft = false
        fileModificationDate = try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        updateChangeCount(.changeCleared)
        rememberLastDocument()
    }
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        do { try persistNow() }
        catch { NSApp.presentError(error) }
        // On errors retain AppKit's unsaved-document review instead of discarding edits.
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    func setPaperStyle(_ style: PaperStyle) {
        guard style != state.note.paperStyle else { return }
        let previous = state.note.paperStyle
        state.note.paperStyle = style
        undoManager?.registerUndo(withTarget: self) { target in target.setPaperStyle(previous) }
        undoManager?.setActionName("용지 변경")
        state.invalidate?(nil)
        state.refresh()
    }

    func eraseStrokes(ids: Set<UUID>) {
        let removed = state.note.strokes.enumerated().compactMap { index, stroke in
            ids.contains(stroke.id) ? (index, stroke) : nil
        }
        guard !removed.isEmpty else { return }
        state.note.strokes.removeAll { ids.contains($0.id) }
        undoManager?.registerUndo(withTarget: self) { target in target.restoreStrokes(removed) }
        undoManager?.setActionName("획 지우기")
        let dirty = removed.reduce(CGRect.null) { $0.union($1.1.bounds) }
        state.invalidate?(dirty)
        state.refresh()
    }
    private func restoreStrokes(_ removed: [(Int, InkStroke)]) {
        for (index, stroke) in removed { state.note.strokes.insert(stroke, at: index) }
        let ids = Set(removed.map { $0.1.id })
        undoManager?.registerUndo(withTarget: self) { target in target.eraseStrokes(ids: ids) }
        undoManager?.setActionName("획 지우기")
        let dirty = removed.reduce(CGRect.null) { $0.union($1.1.bounds) }
        state.invalidate?(dirty)
        state.refresh()
    }

    func moveStrokes(ids: Set<UUID>, by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite,
              delta.width != 0 || delta.height != 0 else { return }
        let moved = state.note.strokes.filter { ids.contains($0.id) }.map { stroke in
            var copy = stroke
            for index in copy.samples.indices {
                copy.samples[index].x += delta.width
                copy.samples[index].y += delta.height
            }
            return copy
        }
        // Keep edited coordinates inside the supported on-disk range.
        guard moved.allSatisfy({ $0.samples.allSatisfy { abs($0.x) <= 100000 && abs($0.y) <= 100000 } }) else { return }
        replaceStrokes(moved)
    }
    func transformStrokes(ids: Set<UUID>, using transform: CGAffineTransform) {
        let changed = state.note.strokes.filter { ids.contains($0.id) }.map { stroke in
            var copy = stroke
            for i in copy.samples.indices {
                let point = copy.samples[i].point.applying(transform)
                copy.samples[i].x = point.x; copy.samples[i].y = point.y
            }
            return copy
        }
        guard changed.allSatisfy({ $0.samples.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100000 && abs($0.y) <= 100000 } }) else { return }
        replaceStrokes(changed, actionName: "선택 크기 변경")
    }
    private func replaceStrokes(_ replacements: [InkStroke], actionName: String = "선택 이동") {
        let lookup = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0) })
        var previous: [InkStroke] = []
        var dirty = CGRect.null
        for index in state.note.strokes.indices {
            let old = state.note.strokes[index]
            guard let replacement = lookup[old.id] else { continue }
            previous.append(old)
            dirty = dirty.union(old.bounds).union(replacement.bounds)
            state.note.strokes[index] = replacement
        }
        guard !previous.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { target in target.replaceStrokes(previous, actionName: actionName) }
        undoManager?.setActionName(actionName)
        state.invalidateStrokeCache?(Set(previous.map(\.id)))
        state.invalidate?(dirty)
        state.refresh()
    }

    func append(_ stroke: InkStroke) {
        let index = state.note.strokes.count
        state.note.strokes.append(stroke)
        undoManager?.registerUndo(withTarget: self) { target in target.remove(at: index) }
        undoManager?.setActionName("필기")
        state.invalidate?(stroke.bounds)
        state.refresh()
    }
    private func remove(at index: Int) {
        guard state.note.strokes.indices.contains(index) else { return }
        let stroke = state.note.strokes.remove(at: index)
        undoManager?.registerUndo(withTarget: self) { target in target.insert(stroke, at: index) }
        undoManager?.setActionName("필기")
        state.invalidate?(stroke.bounds)
        state.refresh()
    }
    private func insert(_ stroke: InkStroke, at index: Int) {
        state.note.strokes.insert(stroke, at: index)
        undoManager?.registerUndo(withTarget: self) { target in target.remove(at: index) }
        undoManager?.setActionName("필기")
        state.invalidate?(stroke.bounds)
        state.refresh()
    }
    @objc func undoInk(_ sender: Any?) {
        state.finishInput?()
        undoManager?.undo()
        state.refresh()
    }
    @objc func redoInk(_ sender: Any?) {
        state.finishInput?()
        undoManager?.redo()
        state.refresh()
    }

    override func data(ofType typeName: String) throws -> Data {
        // NSDocument schedules autosave, handles safe replacement and presents write errors.
        // Encoding happens at save boundaries, never in mouseDragged.
        // Autosave may run while the mouse is held down. Save completed strokes only;
        // never terminate the live stroke or drop its subsequent drag events here.
        let data = try state.note.encoded()
        log.info("Serialized strokes=\(self.state.note.strokes.count) bytes=\(data.count)")
        return data
    }
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try NoteFile.decode(data)
        // Concurrent reading is disabled above, so AppKit calls this on the main thread.
        MainActor.assumeIsolated {
            state.note = decoded
            undoManager?.removeAllActions()
            state.invalidate?(nil)
            state.refresh()
        }
    }
    override func close() {
        state.finishInput?()
        super.close()
    }
}

/// Keep internal legacy filenames and file extensions out of the document title bar.
@MainActor
final class NoteWindowController: NSWindowController {
    static func readableTitle(for url: URL?) -> String {
        guard let url else { return "새 노트" }
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("노트-"), UUID(uuidString: String(name.dropFirst(3))) != nil {
            return "새 노트"
        }
        return name
    }
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        Self.readableTitle(for: document?.fileURL)
    }
}
