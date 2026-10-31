import AppKit
import SwiftUI
@preconcurrency import Sparkle

@MainActor
final class UpdateAvailability: ObservableObject {
    static let shared = UpdateAvailability()
    @Published var version: String?
}

@main
@MainActor
struct LightNoteMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            // Process-local only: diagnostic crashes must not prompt to reopen user windows.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["ApplePersistenceIgnoreState"] = true
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, NSMenuItemValidation {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var preferencesController: NSWindowController?
    private(set) var terminationPending = false
    private var updateSavePending = false
    private var postponedUpdate: (() -> Void)?
    private let documents = LightNoteDocumentController()
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set the running/Dock icon explicitly; old Launch Services entries may cache the placeholder.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSDocumentController.shared.autosavingDelay = 2
        installMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(updatePreferences(_:)),
            name: AppPreferences.changed, object: AppPreferences.shared)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--save-benchmark") {
            Task { @MainActor in
                do { try await AppSelfTest.benchmarkSaving(); exit(0) }
                catch { fputs("SAVE_BENCHMARK_FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--quit-save-test") {
            Task { @MainActor in
                do { try await AppSelfTest.prepareQuitSavingTest() }
                catch { fputs("QUIT_SAVE_TEST_FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            if CommandLine.arguments.contains("--save-tests-only") {
                Task { @MainActor in
                    do {
                        try await AppSelfTest.testBackgroundSaving()
                        print("APP_SELF_TEST_PASSED")
                        exit(0)
                    } catch {
                        fputs("APP_SELF_TEST_FAILED: \(error)\n", stderr)
                        exit(1)
                    }
                }
            } else {
                // Synthetic event fixtures deliberately clean up temporary documents
                // synchronously; keep them isolated from asynchronous lifecycle tests.
                do { try AppSelfTest.run(); print("APP_SELF_TEST_PASSED"); exit(0) }
                catch { fputs("APP_SELF_TEST_FAILED: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if documents.documents.isEmpty {
            documents.openLastDocument()
        }
        updaterController.startUpdater()
    }
    @objc func showPreferences(_ sender: Any?) {
        AppPreferences.shared.syncUpdateSettings(
            checks: updaterController.updater.automaticallyChecksForUpdates,
            downloads: updaterController.updater.automaticallyDownloadsUpdates)
        if preferencesController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "환경설정"
            window.contentMinSize = NSSize(width: 480, height: 500)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView())
            window.center()
            preferencesController = NSWindowController(window: window)
        }
        preferencesController?.showWindow(sender)
        preferencesController?.window?.makeKeyAndOrderFront(sender)
    }
    @objc private func updatePreferences(_ notification: Notification) {
        guard notification.userInfo?["kind"] as? String == "updates",
              !CommandLine.arguments.contains("--self-test") else { return }
        updaterController.updater.automaticallyChecksForUpdates = AppPreferences.shared.automaticChecks
        updaterController.updater.automaticallyDownloadsUpdates = AppPreferences.shared.automaticDownloads
    }
    private var activeNote: NoteDocument? {
        if let settingsWindow = preferencesController?.window, NSApp.keyWindow === settingsWindow { return nil }
        return (NSApp.keyWindow?.windowController?.document as? NoteDocument)
            ?? (NSApp.mainWindow?.windowController?.document as? NoteDocument)
            ?? (documents.currentDocument as? NoteDocument)
            ?? documents.documents.compactMap { $0 as? NoteDocument }.last
    }
    private var currentUndoManager: UndoManager? {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.undoManager }
        return activeNote?.undoManager
    }
    @objc func undoDocument(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo() }
        else { activeNote?.undoInk(sender) }
    }
    @objc func redoDocument(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.redo() }
        else { activeNote?.redoInk(sender) }
    }
    @objc func copyDocumentSelection(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.copy(sender) }
        else { activeNote?.state.copyInk?() }
    }
    @objc func pasteDocumentSelection(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.paste(sender) }
        else { activeNote?.state.pasteInk?() }
    }
    @objc func duplicateDocumentSelection(_ sender: Any?) {
        guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
        activeNote?.state.duplicateInk?()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyDocumentSelection(_:)) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.selectedRange().length > 0 }
            return activeNote?.state.hasSelection ?? false
        }
        if menuItem.action == #selector(pasteDocumentSelection(_:)) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { return editor.isEditable }
            return activeNote != nil && (NSPasteboard.general.availableType(from: [InkCanvasView.inkPasteboardType]) != nil || NSImage.canInit(with: .general))
        }
        if menuItem.action == #selector(duplicateDocumentSelection(_:)) {
            return !(NSApp.keyWindow?.firstResponder is NSTextView) && (activeNote?.state.hasSelection ?? false)
        }
        if menuItem.action == #selector(undoDocument(_:)) { return currentUndoManager?.canUndo ?? false }
        if menuItem.action == #selector(redoDocument(_:)) { return currentUndoManager?.canRedo ?? false }
        return true
    }
    /// Used by both quit and updater relaunch. Recheck all documents after awaits,
    /// including live input completed while another document was being saved.
    func flushDocumentsBeforeExit() async throws {
        repeat {
            for case let document as NoteDocument in documents.documents { document.state.finishInput?() }
            for case let document as NoteDocument in documents.documents { try await document.persistLatest() }
            for case let document as NoteDocument in documents.documents { document.state.finishInput?() }
        } while documents.documents.contains { $0.hasUnautosavedChanges }
    }
    @objc func checkForUpdates(_ sender: Any?) {
        if postponedUpdate != nil { saveBeforeInstallingUpdate() }
        else { updaterController.checkForUpdates(sender) }
    }
    private func saveBeforeInstallingUpdate() {
        guard !updateSavePending else { return }
        updateSavePending = true
        Task { @MainActor in
            defer { updateSavePending = false }
            do {
                try await flushDocumentsBeforeExit()
                // Sparkle may terminate NSApp synchronously. Invoke outside the
                // current main-queue task so AppKit's nested quit loop can run jobs.
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated {
                        let install = self.postponedUpdate
                        self.postponedUpdate = nil
                        install?()
                    }
                }
            } catch { NSApp.presentError(error) }
        }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        UpdateAvailability.shared.version = item.displayVersionString
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        UpdateAvailability.shared.version = nil
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponedUpdate = installHandler
        saveBeforeInstallingUpdate()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            do {
                try await flushDocumentsBeforeExit()
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                if CommandLine.arguments.contains("--self-test") {
                    fputs("EXPECTED_QUIT_SAVE_ERROR: \(error)\n", stderr)
                } else { sender.presentError(error) }
            }
        }
        return .terminateLater
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.openLastDocument() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func installMenu() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            item.submenu = child; menu.addItem(item)
            return child
        }
        func item(_ target: NSMenu, _ title: String, _ action: Selector, _ key: String,
                  modifiers: NSEvent.ModifierFlags = .command) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            target.addItem(entry)
        }
        let app = submenu("LightNote")
        item(app, "LightNote 정보", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        item(app, "환경설정…", #selector(showPreferences(_:)), ",")
        app.items.last?.target = self
        item(app, "업데이트 확인…", #selector(checkForUpdates(_:)), "")
        app.addItem(.separator())
        item(app, "LightNote 가리기", #selector(NSApplication.hide(_:)), "h")
        app.addItem(.separator())
        item(app, "LightNote 종료", #selector(NSApplication.terminate(_:)), "q")
        let file = submenu("파일")
        item(file, "새 노트", #selector(NSDocumentController.newDocument(_:)), "n")
        item(file, "열기…", #selector(NSDocumentController.openDocument(_:)), "o")
        file.addItem(.separator())
        item(file, "닫기", #selector(NSWindow.performClose(_:)), "w")
        item(file, "저장", #selector(NSDocument.save(_:)), "s")
        item(file, "다른 이름으로 저장…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
        let edit = submenu("편집")
        item(edit, "실행 취소", #selector(undoDocument(_:)), "z")
        edit.items.last?.target = self
        item(edit, "다시 실행", #selector(redoDocument(_:)), "Z", modifiers: [.command, .shift])
        edit.items.last?.target = self
        edit.addItem(.separator())
        item(edit, "잘라내기", #selector(NSText.cut(_:)), "x")
        item(edit, "복사", #selector(copyDocumentSelection(_:)), "c")
        edit.items.last?.target = self
        item(edit, "붙여넣기", #selector(pasteDocumentSelection(_:)), "v")
        edit.items.last?.target = self
        item(edit, "복제", #selector(duplicateDocumentSelection(_:)), "d")
        edit.items.last?.target = self
        item(edit, "모두 선택", #selector(NSText.selectAll(_:)), "a")
        let window = submenu("윈도우")
        item(window, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "전체 화면", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        NSApp.windowsMenu = window
        NSApp.mainMenu = menu
    }
}

/// Owns the permanent home of new notes, independently of macOS's window restoration setting.
@MainActor
final class LightNoteDocumentController: NSDocumentController {
    static let lastDocumentKey = "LightNoteLastDocumentPath"
    static var notesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightNote/Notes", isDirectory: true)
    }
    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        let document = try super.makeUntitledDocument(ofType: typeName)
        if let note = document as? NoteDocument { try note.persistNow() }
        return document
    }
    func openLastDocument() {
        if let path = UserDefaults.standard.string(forKey: Self.lastDocumentKey),
           FileManager.default.fileExists(atPath: path) {
            openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { [weak self] document, _, error in
                if let error { NSApp.presentError(error) }
                if document == nil { self?.newDocument(nil) }
            }
        } else {
            newDocument(nil)
        }
    }
}
