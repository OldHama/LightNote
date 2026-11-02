import AppKit
import SwiftUI
import OSLog
import os
import Darwin

private struct FileStamp: Equatable, Sendable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanos: Int64
    var changedSeconds: Int64
    var changedNanos: Int64
    static func read(_ url: URL) throws -> FileStamp {
        var info = stat()
        let path = url.resolvingSymlinksInPath().path
        guard lstat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return FileStamp(device: Int64(info.st_dev), inode: info.st_ino, size: info.st_size,
                         modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                         changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
}

enum RecoveryLocations {
    static let parent: URL = {
        if CommandLine.arguments.contains("--self-test") {
            if let path = ProcessInfo.processInfo.environment["LIGHTNOTE_TEST_DIRECTORY"] { return URL(fileURLWithPath: path) }
            return FileManager.default.temporaryDirectory.appendingPathComponent("LightNote-recovery-tests-"+UUID().uuidString)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LightNote")
    }()
    static var journals: URL { parent.appendingPathComponent("Recovery") }
    static var copies: URL { parent.appendingPathComponent("Notes") }
    static func preserve(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let url = copies.appendingPathComponent("\(RecoveryJournal.safeName(name)) (외부 변경 \(UUID().uuidString)).lightnote")
        try RecoveryJournal.durableWrite(data, to: url)
        return url
    }
}

enum InkTool {
    case pen, eraser, selection, laser, ellipse, rectangle, arrow, freeArrow
    var title: String {
        switch self { case .pen: "볼펜"; case .eraser: "획 지우개"; case .selection: "사각형 선택"; case .laser: "레이저"; case .ellipse: "원 / 타원"; case .rectangle: "사각형"; case .arrow: "화살표"; case .freeArrow: "자유 화살표" }
    }
    var symbol: String {
        switch self { case .pen: "pencil.tip"; case .eraser: "eraser"; case .selection: "selection.pin.in.out"; case .laser: "dot.scope"; case .ellipse: "circle"; case .rectangle: "rectangle"; case .arrow: "arrow.up.right"; case .freeArrow: "arrow.turn.up.right" }
    }
    var hint: String {
        switch self {
        case .pen: "일정한 굵기"
        case .eraser: "닿은 획 전체 삭제"
        case .selection: "영역 선택 후 안쪽을 드래그하여 이동"
        case .arrow: "드래그한 방향으로 화살표 그리기"
        case .freeArrow: "펜처럼 그리고 끝에 화살촉 붙이기"
        case .ellipse, .rectangle: "드래그하여 그리기 · ⌘ 정원 / 정사각형"
        case .laser: "다시 누르면 진하게 복원 · 떼면 1.3초간 서서히 사라짐"
        }
    }
}

/// All access to the value is scoped by the same lock. The yielding accessors
/// preserve in-place edits when no save retains a copy (no permanent mirror).
private final class NoteStorage: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var contents = NoteFile()
    var value: NoteFile {
        _read {
            lock.lock(); defer { lock.unlock() }
            yield contents
        }
        _modify {
            lock.lock(); defer { lock.unlock() }
            yield &contents
        }
    }
    func snapshot() -> NoteFile {
        lock.lock(); defer { lock.unlock() }
        return contents
    }
}

@MainActor
final class NoteState: NSObject, ObservableObject {
    static let eraserRadius: CGFloat = 6
    var refreshCursor: (() -> Void)?
    var invalidateStrokeCache: ((Set<UUID>) -> Void)?
    @Published var recoveryMessage: String?
    @Published var hasSelection = false
    @Published var workspacePageCount = 1
    @Published var visiblePage = 1
    var stickerSelectionPNG: (() throws -> Data?)?
    var insertSticker: ((Data) -> Bool)?
    @Published var showStickers = false
    var copySelectionPNG: (() -> Void)?
    var exportSelectionPNG: (() -> Void)?
    var copyInk: (() -> Void)?
    var pasteInk: (() -> Void)?
    var duplicateInk: (() -> Void)?
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
    nonisolated private let storage = NoteStorage()
    var note: NoteFile {
        _read { yield storage.value }
        _modify { yield &storage.value }
    }
    nonisolated func savingSnapshot() -> NoteFile { storage.snapshot() }
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
    private var isClosed = false
    private var journal: RecoveryJournal?
    private var recoveryBaseData: Data?
    nonisolated private let diskStamp = OSAllocatedUnfairLock<FileStamp?>(initialState: nil)
    nonisolated private let diskDigest = OSAllocatedUnfairLock<Data?>(initialState: nil)
    nonisolated private let encodedDigest = OSAllocatedUnfairLock<Data?>(initialState: nil)
    nonisolated private let writingSnapshot = OSAllocatedUnfairLock<NoteFile?>(initialState: nil)
    private func ensureJournal() throws {
        guard journal == nil, let fileURL else { return }
        let base = try recoveryBaseData ?? Data(contentsOf: fileURL)
        journal = try RecoveryJournal(root: RecoveryLocations.journals, source: fileURL, baseData: base)
        recoveryBaseData = nil
    }
    private func reportRecoveryError(_ error: Error) {
        state.recoveryMessage = "복구 기록 저장 실패 · 노트를 저장해 주세요"
        log.error("Recovery journal error: \(error.localizedDescription)")
    }

    override init() {
        super.init()
        state.document = self
        hasUndoManager = true
    }
    // AppKit serializes file access and tracks the save's change-count token.
    // Only the immutable NoteFile snapshot crosses into its writing thread.
    nonisolated private let writtenFileTestObserver = OSAllocatedUnfairLock<(@Sendable () throws -> Void)?>(initialState: nil)
    func observeWrittenFileForTesting(_ observer: (@Sendable () throws -> Void)?) {
        precondition(CommandLine.arguments.contains("--self-test"))
        writtenFileTestObserver.withLock { $0 = observer }
    }
    nonisolated private let saveTestObserver = OSAllocatedUnfairLock<(@Sendable (NoteFile, Bool) throws -> Void)?>(initialState: nil)
    func observeSavesForTesting(_ observer: (@Sendable (NoteFile, Bool) throws -> Void)?) {
        precondition(CommandLine.arguments.contains("--self-test"))
        saveTestObserver.withLock { $0 = observer }
    }
    nonisolated override func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                                    for saveOperation: NSDocument.SaveOperationType) -> Bool { true }
    override class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func makeWindowControllers() {
        if !CommandLine.arguments.contains("--self-test"), fileURL == nil {
            do { try persistNow() } catch { NSApp.presentError(error) }
        }
        do { try ensureJournal() } catch { reportRecoveryError(error) }
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

    private func destinationForSaving(directory: URL? = nil) throws -> URL {
        if let fileURL { return fileURL }
        let folder = directory ?? LightNoteDocumentController.notesDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var number = 1
        var candidate = folder.appendingPathComponent("새 노트.lightnote")
        while FileManager.default.fileExists(atPath: candidate.path) {
            number += 1
            candidate = folder.appendingPathComponent("새 노트 \(number).lightnote")
        }
        return candidate
    }
    /// Synchronous helper for initial empty files and isolated diagnostics only.
    func persistNow(directory: URL? = nil) throws {
        state.finishInput?()
        let type = fileType ?? "com.lightnote.note"
        let destination = try destinationForSaving(directory: directory)
        try writeSafely(to: destination, ofType: type, for: .saveOperation)
        fileURL = destination
        fileType = type
        isDraft = false
        fileModificationDate = try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        updateChangeCount(.changeCleared)
        rememberLastDocument()
    }
    /// Finish current input and save through AppKit's asynchronous, ordered safe writer.
    /// A successful old snapshot must not clear edits made while it was being written.
    func persistLatest(directory: URL? = nil) async throws {
        state.finishInput?()
        repeat {
            let destination = try destinationForSaving(directory: directory)
            try await save(to: destination, ofType: fileType ?? "com.lightnote.note", for: .saveOperation)
            state.finishInput?()
        } while hasUnautosavedChanges
        rememberLastDocument()
    }
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        state.finishInput?()
        // autosavesInPlace makes AppKit wait for non-cancellable async saving before
        // granting close. Its normal error/recovery UI remains in charge of failures.
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    // The canvas edits a value model directly, outside Cocoa text bindings. Record
    // each model mutation explicitly, including edits made while an older save runs.
    // Ignore UndoManager's group notifications to avoid counting a mutation twice.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        switch change {
        case .changeDone, .changeUndone, .changeRedone: return
        default: super.updateChangeCount(change)
        }
    }
    private func contentDidChange(_ delta: RecoveryDelta) {
        do { try ensureJournal(); try journal?.append(delta) }
        catch { reportRecoveryError(error) }
        if undoManager?.isUndoing == true { super.updateChangeCount(.changeUndone) }
        else if undoManager?.isRedoing == true { super.updateChangeCount(.changeRedone) }
        else { super.updateChangeCount(.changeDone) }
    }

    func setPaperStyle(_ style: PaperStyle) {
        guard style != state.note.paperStyle else { return }
        let previous = state.note.paperStyle
        state.note.paperStyle = style
        undoManager?.registerUndo(withTarget: self) { target in target.setPaperStyle(previous) }
        undoManager?.setActionName("용지 변경")
        state.invalidate?(nil)
        contentDidChange(RecoveryDelta(paper: style))
        state.refresh()
    }

    func eraseStrokes(ids: Set<UUID>, actionName: String = "획 지우기") {
        let ids = Set(state.note.strokes.filter { ids.contains($0.id) && !$0.isLocked }.map(\.id))
        let removed = state.note.strokes.enumerated().compactMap { index, stroke in
            ids.contains(stroke.id) ? (index, stroke) : nil
        }
        guard !removed.isEmpty else { return }
        state.note.strokes.removeAll { ids.contains($0.id) }
        undoManager?.registerUndo(withTarget: self) { target in target.restoreStrokes(removed, actionName: actionName) }
        undoManager?.setActionName(actionName)
        let dirty = removed.reduce(CGRect.null) { $0.union($1.1.bounds) }
        state.invalidate?(dirty)
        contentDidChange(RecoveryDelta(removed: removed.map { $0.1.id }))
        state.refresh()
    }
    private func restoreStrokes(_ removed: [(Int, InkStroke)], actionName: String) {
        for (index, stroke) in removed { state.note.strokes.insert(stroke, at: index) }
        let ids = Set(removed.map { $0.1.id })
        undoManager?.registerUndo(withTarget: self) { target in target.eraseStrokes(ids: ids, actionName: actionName) }
        undoManager?.setActionName(actionName)
        let dirty = removed.reduce(CGRect.null) { $0.union($1.1.bounds) }
        state.invalidate?(dirty)
        contentDidChange(RecoveryDelta(puts: removed.map { .init(index: $0.0, stroke: $0.1) }))
        state.refresh()
    }

    func moveStrokes(ids: Set<UUID>, by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite,
              delta.width != 0 || delta.height != 0 else { return }
        let moved = state.note.strokes.filter { ids.contains($0.id) && !$0.isLocked }.map { stroke in
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
        let changed = state.note.strokes.filter { ids.contains($0.id) && !$0.isLocked }.map { stroke in
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
    func setLocked(ids: Set<UUID>, locked: Bool) {
        let changed = state.note.strokes.filter { ids.contains($0.id) && $0.isLocked != locked }.map { stroke in
            var copy = stroke; copy.locked = locked ? true : nil; return copy
        }
        guard !changed.isEmpty else { return }
        replaceStrokes(changed, actionName: locked ? "객체 잠금" : "객체 잠금 해제")
    }
    private func replaceStrokes(_ replacements: [InkStroke], actionName: String = "선택 이동") {
        let lookup = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0) })
        var previous: [InkStroke] = []
        var puts: [RecoveryDelta.Put] = []
        var dirty = CGRect.null
        for index in state.note.strokes.indices {
            let old = state.note.strokes[index]
            guard let replacement = lookup[old.id] else { continue }
            previous.append(old)
            puts.append(.init(index: index, stroke: replacement))
            dirty = dirty.union(old.bounds).union(replacement.bounds)
            state.note.strokes[index] = replacement
        }
        guard !previous.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { target in target.replaceStrokes(previous, actionName: actionName) }
        undoManager?.setActionName(actionName)
        state.invalidateStrokeCache?(Set(previous.map(\.id)))
        state.invalidate?(dirty)
        contentDidChange(RecoveryDelta(puts: puts))
        state.refresh()
    }

    func appendStrokes(_ strokes: [InkStroke], actionName: String) {
        guard !strokes.isEmpty else { return }
        let ids = Set(strokes.map(\.id))
        guard ids.count == strokes.count, !state.note.strokes.contains(where: { ids.contains($0.id) }) else { return }
        let firstIndex = state.note.strokes.count
        state.note.strokes.append(contentsOf: strokes)
        undoManager?.registerUndo(withTarget: self) { target in target.eraseStrokes(ids: ids, actionName: actionName) }
        undoManager?.setActionName(actionName)
        state.invalidate?(strokes.reduce(CGRect.null) { $0.union($1.bounds) })
        contentDidChange(RecoveryDelta(puts: strokes.enumerated().map { .init(index: firstIndex+$0.offset, stroke: $0.element) }))
        state.refresh()
    }

    func append(_ stroke: InkStroke) {
        let index = state.note.strokes.count
        state.note.strokes.append(stroke)
        undoManager?.registerUndo(withTarget: self) { target in target.remove(at: index) }
        undoManager?.setActionName("필기")
        state.invalidate?(stroke.bounds)
        contentDidChange(RecoveryDelta(puts: [.init(index: index, stroke: stroke)]))
        state.refresh()
    }
    private func remove(at index: Int) {
        guard state.note.strokes.indices.contains(index) else { return }
        let stroke = state.note.strokes.remove(at: index)
        undoManager?.registerUndo(withTarget: self) { target in target.insert(stroke, at: index) }
        undoManager?.setActionName("필기")
        state.invalidate?(stroke.bounds)
        contentDidChange(RecoveryDelta(removed: [stroke.id]))
        state.refresh()
    }
    private func insert(_ stroke: InkStroke, at index: Int) {
        state.note.strokes.insert(stroke, at: index)
        undoManager?.registerUndo(withTarget: self) { target in target.remove(at: index) }
        undoManager?.setActionName("필기")
        state.invalidate?(stroke.bounds)
        contentDidChange(RecoveryDelta(puts: [.init(index: index, stroke: stroke)]))
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

    override func save(to url: URL, ofType typeName: String, for operation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let previousURL = fileURL
        super.save(to: url, ofType: typeName, for: operation) { error in
            guard let error else {
                self.rememberReplacement(from: previousURL)
                if let current = self.fileURL {
                    do { try self.journal?.retarget(to: current) } catch { self.reportRecoveryError(error) }
                }
                completionHandler(nil); return
            }
            guard operation == .saveOperation || operation == .autosaveInPlaceOperation,
                  let expected = self.diskDigest.withLock({ $0 }) else { completionHandler(error); return }
            // AppKit may reject an externally modified file BEFORE writeSafely.
            // The user prefers the open document to win over external changes.
            Task { @MainActor in
                let changed = await Task.detached {
                    guard let data = try? Data(contentsOf: url) else { return false }
                    return RecoveryJournal.digest(data) != expected
                }.value
                guard changed else { completionHandler(error); return }
                do {
                    try await self.overwriteCurrentFile(to: url, typeName: typeName)
                    self.rememberReplacement(from: previousURL)
                    try self.journal?.retarget(to: url)
                    completionHandler(nil)
                } catch { completionHandler(error) }
            }
        }
    }
    func libraryDidMove(from previous: URL) throws {
        if let current = fileURL { try journal?.retarget(to:current) }
        diskStamp.withLock { $0 = nil }
        rememberReplacement(from:previous)
    }
    private func rememberReplacement(from previous: URL?) {
        guard !CommandLine.arguments.contains("--self-test"), let previous, let current = fileURL else { return }
        let key = LightNoteDocumentController.lastDocumentKey
        let oldPath = UserDefaults.standard.string(forKey: key)
        let updated = LightNoteDocumentController.retargetedPath(oldPath, from: previous, to: current)
        if updated != oldPath { UserDefaults.standard.set(updated, forKey: key) }
    }
    private func overwriteCurrentFile(to url: URL, typeName: String) async throws {
        try await super.save(to: url, ofType: typeName, for: .saveAsOperation)
    }

    nonisolated override func writeSafely(to url: URL, ofType typeName: String,
                                          for operation: NSDocument.SaveOperationType) throws {
        let snapshot = state.savingSnapshot()
        writingSnapshot.withLock { $0 = snapshot }
        defer { writingSnapshot.withLock { $0 = nil } }
        unblockUserInteraction()
        try super.writeSafely(to: url, ofType: typeName, for: operation)
        if operation == .saveOperation || operation == .saveAsOperation || operation == .autosaveInPlaceOperation {
            let digest = encodedDigest.withLock { $0 }
            diskDigest.withLock { $0 = digest }
            let stamp = try FileStamp.read(url)
            diskStamp.withLock { $0 = stamp }
        }
    }
    nonisolated override func presentedItemDidChange() {
        // Keep the open model authoritative; the next save replaces external bytes.
        diskStamp.withLock { $0 = nil }
    }

    nonisolated override func write(to url: URL, ofType typeName: String) throws {
        try super.write(to: url, ofType: typeName)
        let observer = writtenFileTestObserver.withLock { $0 }
        try observer?()
    }

    nonisolated override func data(ofType typeName: String) throws -> Data {
        // AppKit blocks main-thread interaction until we release it below. The
        // lock also covers direct diagnostic calls and any overlapping model access.
        // Do not dispatch to main here: AppKit may be synchronously waiting for us.
        let snapshot = writingSnapshot.withLock { $0 } ?? state.savingSnapshot()
        // Release interaction BEFORE encoding. Later edits use Swift copy-on-write;
        // AppKit's token leaves those edits dirty when this snapshot finishes.
        unblockUserInteraction()
        let observer = saveTestObserver.withLock { $0 }
        try observer?(snapshot, Thread.isMainThread)
        let data = try snapshot.encoded()
        let digest = RecoveryJournal.digest(data)
        encodedDigest.withLock { $0 = digest }
        log.info("Serialized strokes=\(snapshot.strokes.count) bytes=\(data.count)")
        return data
    }
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try NoteFile.decode(data)
        // Concurrent reading is disabled above, so AppKit calls this on the main thread.
        MainActor.assumeIsolated {
            try? journal?.discard()
            journal = nil
            recoveryBaseData = data
            let digest = RecoveryJournal.digest(data)
            diskDigest.withLock { $0 = digest }
            diskStamp.withLock { $0 = nil }
            state.note = decoded
            undoManager?.removeAllActions()
            state.invalidate?(nil)
            state.refresh()
        }
    }
    override func close() {
        state.finishInput?()
        isClosed = true
        // Normal close follows AppKit's save/discard review. SIGKILL cannot reach here.
        do { try journal?.discard(); journal = nil } catch { reportRecoveryError(error) }
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
        for kind in ["복구", "충돌"] {
            if let range = name.range(of: " ("+kind+" ") { return String(name[..<range.lowerBound]) + " ("+kind+")" }
        }
        return name
    }
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        Self.readableTitle(for: document?.fileURL)
    }
}
