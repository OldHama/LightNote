import AppKit
@preconcurrency import Sparkle

@main
@MainActor
struct LightNoteMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
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
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--self-test") {
            do {
                try AppSelfTest.run()
                print("APP_SELF_TEST_PASSED")
                exit(0)
            } catch {
                fputs("APP_SELF_TEST_FAILED: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        if documents.documents.isEmpty {
            documents.openLastDocument()
        }
        updaterController.startUpdater()
    }
    @objc private func checkForUpdates(_ sender: Any?) {
        if let install = postponedUpdate {
            do {
                for case let document as NoteDocument in documents.documents { try document.persistNow() }
                postponedUpdate = nil
                install()
            } catch { NSApp.presentError(error) }
        } else { updaterController.checkForUpdates(sender) }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        do {
            for case let document as NoteDocument in documents.documents { try document.persistNow() }
            return false
        } catch {
            postponedUpdate = installHandler
            NSApp.presentError(error)
            return true
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            for case let document as NoteDocument in documents.documents { try document.persistNow() }
            return .terminateNow
        } catch {
            sender.presentError(error)
            return .terminateCancel
        }
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
        item(edit, "실행 취소", Selector(("undo:")), "z")
        item(edit, "다시 실행", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        item(edit, "잘라내기", #selector(NSText.cut(_:)), "x")
        item(edit, "복사", #selector(NSText.copy(_:)), "c")
        item(edit, "붙여넣기", #selector(NSText.paste(_:)), "v")
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
