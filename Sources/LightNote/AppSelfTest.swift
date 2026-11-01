import AppKit
import ImageIO
import SwiftUI
import os

/// In-process native event integration checks. These do not simulate Sidecar hardware.
@MainActor
enum AppSelfTest {
    struct Failure: Error { let message: String }
    static func run() throws {
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw Failure(message: message) }
        }
        let doc = NoteDocument()
        NSDocumentController.shared.addDocument(doc)
        try expect(doc.state.note.paperStyle == .grid, "New note should default to grid")
        doc.state.note.paperStyle = .blank // Fixture for paper switching undo checks below.
        doc.makeWindowControllers()
        let window = doc.windowControllers[0].window!
        window.makeKeyAndOrderFront(nil)
        let canvas = InkCanvasView(state: doc.state)
        window.contentView = canvas
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, _ time: Double, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            let location = canvas.convert(CGPoint(x: x, y: y), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        doc.undoManager?.groupsByEvent = false
        func begin() { doc.undoManager?.beginUndoGrouping() }
        func end() { doc.undoManager?.endUndoGrouping(); doc.state.refresh() }
        // 100 taps, including identical down/up coordinates, must remain separate visible dots.
        for i in 0..<100 {
            begin()
            canvas.mouseDown(with: event(.leftMouseDown, Double(30 + i % 20 * 20), Double(30 + i / 20 * 20), Double(i)))
            canvas.mouseUp(with: event(.leftMouseUp, Double(30 + i % 20 * 20), Double(30 + i / 20 * 20), Double(i) + 0.01))
            end()
        }
        try expect(doc.state.note.strokes.count == 100, "Lost taps")
        doc.state.width = 3
        doc.state.color = .blue
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 40, 200, 200))
        for i in 1...2000 {
            if i == 1000 {
                let snapshot = try NoteFile.decode(doc.data(ofType: "com.lightnote.note"))
                try expect(snapshot.strokes.count == 100, "Save should snapshot completed strokes")
            }
            canvas.mouseDragged(with: event(.leftMouseDragged, 40 + Double(i % 600),
                220 + sin(Double(i) / 20) * 40, 200 + Double(i) / 10000))
        }
        canvas.mouseUp(with: event(.leftMouseUp, 300, 220, 201))
        end()
        try expect(doc.state.note.strokes.last?.samples.count == 2002, "Lost drag samples")
        try expect(doc.state.note.strokes.last?.width == 3 && doc.state.note.strokes.last?.color == .blue, "Style lost")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes.count == 100, "Undo failed")
        doc.redoInk(nil)
        try expect(doc.state.note.strokes.count == 101, "Redo failed")
        // Interrupted input is committed, and orphan drags must not reconnect it.
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 50, 400, 300))
        canvas.finishStroke(reason: "test-disconnect")
        end()
        canvas.mouseDragged(with: event(.leftMouseDragged, 600, 700, 301))
        try expect(doc.state.note.strokes.last?.samples.count == 1, "Disconnected stroke connected")
        let image = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: image)
        let pixelX = Int(30 * Double(image.pixelsWide) / canvas.bounds.width)
        let pixelY = Int(30 * Double(image.pixelsHigh) / canvas.bounds.height)
        let dot = image.colorAt(x: pixelX, y: pixelY)!.usingColorSpace(.sRGB)!
        try expect(dot.redComponent < 0.9, "Dot not rendered")
        let strokesBeforePaperChange = doc.state.note.strokes
        begin()
        doc.setPaperStyle(.grid)
        end()
        try expect(doc.state.note.strokes == strokesBeforePaperChange, "Paper change modified ink")
        doc.undoInk(nil)
        try expect(doc.state.note.paperStyle == .blank, "Paper undo failed")
        doc.redoInk(nil)
        try expect(doc.state.note.paperStyle == .grid, "Paper redo failed")
        canvas.cacheDisplay(in: canvas.bounds, to: image)
        let gridX = Int(20 * Double(image.pixelsWide) / canvas.bounds.width)
        let gridY = Int(180 * Double(image.pixelsHigh) / canvas.bounds.height)
        let gridPixel = image.colorAt(x: gridX, y: gridY)!.usingColorSpace(.sRGB)!
        try expect(gridPixel.redComponent < 0.99, "Grid not rendered")
        let originalStrokes = doc.state.note.strokes
        let eraserKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 400, windowNumber: window.windowNumber, context: nil,
            characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14)!
        canvas.keyDown(with: eraserKey)
        try expect(doc.state.tool == .eraser, "E did not select eraser")
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 30, 30, 401))
        canvas.mouseUp(with: event(.leftMouseUp, 30, 30, 402))
        end()
        try expect(doc.state.note.strokes.count == originalStrokes.count - 1, "Dot erase failed")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes == originalStrokes, "Erase undo changed order or data")
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 10, 30, 403))
        canvas.mouseDragged(with: event(.leftMouseDragged, 450, 30, 404))
        canvas.mouseUp(with: event(.leftMouseUp, 450, 30, 405))
        end()
        try expect(doc.state.note.strokes.count == originalStrokes.count - 20, "Fast swept erase missed dots")
        let erasedSnapshot = try NoteFile.decode(doc.data(ofType: "com.lightnote.note"))
        try expect(erasedSnapshot.strokes == doc.state.note.strokes, "Erased strokes persisted")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes == originalStrokes, "Gesture undo failed")
        doc.redoInk(nil)
        try expect(doc.state.note.strokes.count == originalStrokes.count - 20, "Erase redo failed")
        doc.undoInk(nil)
        let penKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 406, windowNumber: window.windowNumber, context: nil,
            characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
        canvas.keyDown(with: penKey)
        try expect(doc.state.tool == .pen, "P did not restore pen")
        let beforeSelection = doc.state.note.strokes
        let selectKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 410, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        canvas.keyDown(with: selectKey)
        try expect(doc.state.tool == .selection, "V did not select rectangle tool")
        canvas.mouseDown(with: event(.leftMouseDown, 20, 20, 411))
        canvas.mouseDragged(with: event(.leftMouseDragged, 420, 40, 412))
        canvas.mouseUp(with: event(.leftMouseUp, 420, 40, 413))
        try expect(doc.state.note.strokes == beforeSelection, "Selection changed ink")
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 100, 30, 414))
        canvas.mouseDragged(with: event(.leftMouseDragged, 700, 630, 415))
        try expect(doc.state.note.strokes == beforeSelection, "Move preview mutated document")
        canvas.mouseUp(with: event(.leftMouseUp, 700, 630, 416))
        end()
        var expectedMove = beforeSelection
        for i in 0..<20 {
            for j in expectedMove[i].samples.indices {
                expectedMove[i].samples[j].x += 600
                expectedMove[i].samples[j].y += 600
            }
        }
        try expect(doc.state.note.strokes == expectedMove, "Selection moved wrong strokes or lost metadata")
        let movedFile = try NoteFile.decode(doc.data(ofType: "com.lightnote.note"))
        try expect(movedFile.strokes == expectedMove, "Moved strokes not saved")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes == beforeSelection, "Move undo not exact")
        doc.redoInk(nil)
        try expect(doc.state.note.strokes == expectedMove, "Move redo not exact")
        doc.undoInk(nil)
        let backspace = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 417, windowNumber: window.windowNumber, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        begin(); canvas.keyDown(with: backspace); end()
        try expect(doc.state.note.strokes == Array(beforeSelection.dropFirst(20)), "Backspace deleted wrong selection")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes == beforeSelection, "Selection delete undo not exact")
        doc.redoInk(nil)
        try expect(doc.state.note.strokes == Array(beforeSelection.dropFirst(20)), "Selection delete redo failed")
        doc.undoInk(nil)
        canvas.keyDown(with: backspace)
        try expect(doc.state.note.strokes == beforeSelection, "Backspace with no selection deleted ink")
        doc.state.selectTool(.pen)
        let scroll = InkScrollView(state: doc.state)
        window.contentView = scroll
        scroll.documentView = canvas
        canvas.setFrameSize(NSSize(width: doc.state.note.pageWidth, height: doc.state.note.pageHeight))
        window.layoutIfNeeded()
        let inkBeforeZoom = doc.state.note.strokes
        try expect(scroll.allowsMagnification && scroll.minMagnification == 0.25 && scroll.maxMagnification == 4,
                   "Pinch zoom not enabled")
        for (index, scale) in [CGFloat(2), CGFloat(0.5)].enumerated() {
            scroll.setMagnification(scale, centeredAt: CGPoint(x: 700, y: 500))
            try expect(abs(scroll.magnification - scale) < 0.001, "Zoom scale failed")
            try expect(doc.state.note.strokes == inkBeforeZoom, "Zoom mutated vector data")
            let origin = canvas.convert(CGPoint(x: 700, y: 500), to: nil)
            let offset = canvas.convert(CGPoint(x: 710, y: 500), to: nil)
            try expect(abs(abs(offset.x - origin.x) - 10 * scale) < 0.01, "Zoom transform incorrect")
            let time = 500 + Double(index) * 10
            begin()
            canvas.mouseDown(with: event(.leftMouseDown, 700, 500, time))
            canvas.mouseUp(with: event(.leftMouseUp, 700, 500, time + 1))
            end()
            let point = doc.state.note.strokes.last!.samples.first!
            try expect(abs(point.x - 700) < 0.01 && abs(point.y - 500) < 0.01, "Zoomed ink coordinate drift")
            doc.state.selectTool(.selection)
            canvas.mouseDown(with: event(.leftMouseDown, 690, 490, time + 1.1))
            canvas.mouseUp(with: event(.leftMouseUp, 710, 510, time + 1.2))
            begin()
            canvas.mouseDown(with: event(.leftMouseDown, 700, 500, time + 1.3))
            canvas.mouseUp(with: event(.leftMouseUp, 730, 530, time + 1.4))
            end()
            let shifted = doc.state.note.strokes.last!.samples.first!
            try expect(abs(shifted.x - 730) < 0.01 && abs(shifted.y - 530) < 0.01, "Zoomed selection move drift")
            doc.undoInk(nil)
            doc.state.selectTool(.eraser)
            begin()
            canvas.mouseDown(with: event(.leftMouseDown, 707.5, 500, time + 2))
            canvas.mouseUp(with: event(.leftMouseUp, 707.5, 500, time + 3))
            end()
            try expect(doc.state.note.strokes == inkBeforeZoom, "Zoomed eraser missed target")
            doc.state.selectTool(.pen)
        }
        doc.state.resetZoom?()
        try expect(scroll.magnification == 1 && doc.state.zoom == 1, "Zoom reset failed")
        scroll.setMagnification(0.25, centeredAt: .zero)
        scroll.ensureCanvasCoverage()
        let viewport = scroll.contentView.bounds
        try expect(canvas.bounds.width >= viewport.width && canvas.bounds.height >= viewport.height,
                   "Zoomed-out viewport extends beyond writable canvas")
        try expect(canvas.bounds.width > 1800 && canvas.bounds.height > 1600, "Workspace did not grow")
        let gridRegion = CGRect(x: 1000, y: 1300, width: 40, height: 40)
        let outerGrid = canvas.bitmapImageRepForCachingDisplay(in: gridRegion)!
        canvas.cacheDisplay(in: gridRegion, to: outerGrid)
        var gridVisible = false
        for x in 0..<outerGrid.pixelsWide {
            for y in 0..<outerGrid.pixelsHigh {
                if let color = outerGrid.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.999 {
                    gridVisible = true
                }
            }
        }
        try expect(gridVisible, "Grid missing outside original A4 bounds")
        for (index, point) in [CGPoint(x: 1000, y: 1300), CGPoint(x: 1800, y: 1600)].enumerated() {
            let windowPoint = canvas.convert(point, to: nil)
            let hitPoint = scroll.convert(windowPoint, from: nil)
            try expect(scroll.hitTest(hitPoint) === canvas, "Outer viewport does not receive canvas input")
            begin()
            canvas.mouseDown(with: event(.leftMouseDown, point.x, point.y, 600 + Double(index) * 2))
            canvas.mouseUp(with: event(.leftMouseUp, point.x, point.y, 601 + Double(index) * 2))
            end()
            let stored = doc.state.note.strokes.last!.samples.first!
            try expect(abs(stored.x - point.x) < 0.01 && abs(stored.y - point.y) < 0.01,
                       "Cannot write outside original A4 bounds")
        }
        let outerInk = doc.state.note.strokes
        doc.state.selectTool(.eraser)
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 1800, 1600, 610))
        canvas.mouseUp(with: event(.leftMouseUp, 1800, 1600, 611))
        end()
        try expect(doc.state.note.strokes.count == outerInk.count - 1, "Outer viewport eraser failed")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes == outerInk, "Outer viewport erase undo failed")
        doc.state.selectTool(.pen)
        window.setContentSize(NSSize(width: 1440, height: 960))
        window.layoutIfNeeded()
        scroll.ensureCanvasCoverage()
        try expect(canvas.bounds.width >= scroll.contentView.bounds.width &&
                   canvas.bounds.height >= scroll.contentView.bounds.height, "Window resize exposes nonwritable area")
        let expandedSize = canvas.frame.size
        begin(); doc.setPaperStyle(.blank); end()
        begin(); doc.setPaperStyle(.grid); end()
        try expect(canvas.frame.size == expandedSize, "Paper switch shrank workspace")
        let data = try doc.data(ofType: "com.lightnote.note")
        let reopened = NoteDocument()
        try reopened.read(from: data, ofType: "com.lightnote.note")
        try expect(reopened.state.note == doc.state.note, "Roundtrip differs")
        let restoredCanvas = InkCanvasView(state: reopened.state)
        try expect(restoredCanvas.bounds.width > 1800 && restoredCanvas.bounds.height > 1600,
                   "Reopened canvas clips stored ink")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lightnote")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.write(to: url, ofType: "com.lightnote.note", for: .saveOperation, originalContentsURL: nil)
        let onDisk = try NoteFile.decode(Data(contentsOf: url))
        try expect(onDisk == doc.state.note, "Disk save differs")
        let before = reopened.state.note
        do {
            try reopened.read(from: Data("broken".utf8), ofType: "com.lightnote.note")
            throw Failure(message: "Corrupt file accepted")
        } catch is DecodingError {}
        try expect(reopened.state.note == before, "Failed read destroyed open document")
        let managedFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managedFolder) }
        let managed = NoteDocument()
        try managed.persistNow(directory: managedFolder)
        let managedURL = managed.fileURL!
        try expect(managedURL.lastPathComponent == "새 노트.lightnote", "New note name is not readable")
        try expect(NoteWindowController.readableTitle(for: URL(fileURLWithPath: "/tmp/노트-" + UUID().uuidString + ".lightnote")) == "새 노트", "Legacy UUID exposed in title")
        try expect(NoteWindowController.readableTitle(for: URL(fileURLWithPath: "/tmp/수학 정리.lightnote")) == "수학 정리", "User title not preserved")
        let secondManaged = NoteDocument()
        try secondManaged.persistNow(directory: managedFolder)
        try expect(secondManaged.fileURL?.lastPathComponent == "새 노트 2.lightnote", "New note overwrote existing file")
        secondManaged.close()
        try expect(FileManager.default.fileExists(atPath: managedURL.path), "New note not automatically stored")
        try expect(!managed.isDraft && NoteDocument.autosavesDrafts == false, "Managed note remains a draft")
        managed.undoManager?.groupsByEvent = false
        managed.undoManager?.beginUndoGrouping()
        managed.append(InkStroke(samples: [InkSample(x: 10, y: 20, time: 1)]))
        managed.undoManager?.endUndoGrouping()
        try managed.persistNow(directory: managedFolder)
        try expect(managed.fileURL == managedURL && !managed.isDocumentEdited, "Managed save changed path or retained edits")
        let automaticReopen = try NoteDocument(contentsOf: managedURL, ofType: "com.lightnote.note")
        try expect(automaticReopen.state.note == managed.state.note, "Managed note reopen failed")
        automaticReopen.close()
        managed.close()
        let beforeLaser = doc.state.note
        let undoBeforeLaser = doc.undoManager?.canUndo
        let laserKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 700, windowNumber: window.windowNumber, context: nil,
            characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)!
        canvas.keyDown(with: laserKey)
        try expect(doc.state.tool == .laser, "L did not select laser")
        canvas.mouseDown(with: event(.leftMouseDown, 100, 500, 701))
        canvas.mouseDragged(with: event(.leftMouseDragged, 300, 550, 702))
        canvas.finishStroke(reason: "document-action")
        canvas.finishStroke(reason: "display-change")
        canvas.keyDown(with: laserKey)
        canvas.advanceLaser(now: ProcessInfo.processInfo.systemUptime + 100, leftButtonDown: true)
        try expect(canvas.visibleLaserTraceCount == 1, "Held laser expired")
        let laserSnapshot = try NoteFile.decode(doc.data(ofType: "com.lightnote.note"))
        try expect(laserSnapshot == beforeLaser, "Laser was saved as ink")
        canvas.mouseUp(with: event(.leftMouseUp, 300, 550, 703))
        try expect(canvas.visibleLaserTraceCount == 1, "Released laser vanished immediately")
        canvas.mouseDown(with: event(.leftMouseDown, 350, 550, 704))
        canvas.advanceLaser(now: ProcessInfo.processInfo.systemUptime + 100, leftButtonDown: true)
        try expect(canvas.visibleLaserTraceCount == 2, "Previous laser faded during new hold")
        try expect(canvas.laserIsFullyVisible, "Re-click did not restore full laser brightness")
        canvas.mouseUp(with: event(.leftMouseUp, 360, 560, 705))
        canvas.advanceLaser(now: ProcessInfo.processInfo.systemUptime + 1.4, leftButtonDown: false)
        try expect(canvas.visibleLaserTraceCount == 0, "Released laser did not expire")
        try expect(doc.state.note == beforeLaser && doc.undoManager?.canUndo == undoBeforeLaser,
                   "Laser changed ink or undo history")
        doc.state.selectTool(.pen)
        func toolKey(_ value: String, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 800,
                windowNumber: window.windowNumber, context: nil, characters: value,
                charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)!
        }
        canvas.keyDown(with: toolKey("r", code: 15))
        try expect(doc.state.tool == .rectangle, "R did not select rectangle")
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 2500, 2000, 801))
        canvas.mouseDragged(with: event(.leftMouseDragged, 2600, 2050, 802))
        canvas.mouseUp(with: event(.leftMouseUp, 2600, 2050, 803))
        end()
        let rectangle = doc.state.note.strokes.last!
        try expect(rectangle.tool == "rectangle" && rectangle.pointBounds.width == 100 && rectangle.pointBounds.height == 50,
                   "Rectangle dimensions incorrect")
        canvas.keyDown(with: toolKey("c", code: 8))
        try expect(doc.state.tool == .ellipse, "C did not select ellipse")
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 2800, 2000, 804, modifiers: .command))
        canvas.mouseUp(with: event(.leftMouseUp, 2900, 2050, 805, modifiers: .command))
        end()
        let circle = doc.state.note.strokes.last!
        try expect(circle.tool == "ellipse" && abs(circle.pointBounds.width-circle.pointBounds.height) < 1e-9,
                   "Command did not constrain circle")
        canvas.keyDown(with: toolKey("v", code: 9))
        canvas.mouseDown(with: event(.leftMouseDown, 2490, 1990, 806))
        canvas.mouseUp(with: event(.leftMouseUp, 2610, 2060, 807))
        let beforeResize = doc.state.note.strokes
        let margin = 5 / scroll.magnification
        let frame = rectangle.bounds.insetBy(dx: -margin, dy: -margin)
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, frame.maxX, frame.maxY, 808))
        canvas.mouseDragged(with: event(.leftMouseDragged, frame.maxX+frame.width, frame.maxY+frame.height, 809))
        try expect(doc.state.note.strokes == beforeResize, "Resize preview mutated ink")
        canvas.mouseUp(with: event(.leftMouseUp, frame.maxX+frame.width, frame.maxY+frame.height, 810))
        end()
        let enlarged = doc.state.note.strokes.first { $0.id == rectangle.id }!
        try expect(abs(enlarged.pointBounds.width-200) < 1e-9 && abs(enlarged.pointBounds.height-100) < 1e-9,
                   "Corner handle did not enlarge shape")
        try expect(doc.state.note.strokes.last == circle, "Resize changed unselected circle")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes == beforeResize, "Resize undo not exact")
        doc.redoInk(nil)
        try expect(doc.state.note.strokes.first { $0.id == rectangle.id } == enlarged, "Resize redo failed")
        doc.undoInk(nil)
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, frame.minX, frame.minY, 811))
        canvas.mouseUp(with: event(.leftMouseUp, frame.midX, frame.midY, 812))
        end()
        let smaller = doc.state.note.strokes.first { $0.id == rectangle.id }!
        try expect(abs(smaller.pointBounds.width-50) < 1e-9 && abs(smaller.pointBounds.height-25) < 1e-9,
                   "Opposite corner handle did not shrink shape")
        doc.undoInk(nil)
        let shapeFile = try NoteFile.decode(doc.data(ofType: "com.lightnote.note"))
        try expect(shapeFile.strokes == doc.state.note.strokes, "Shape roundtrip failed")
        doc.state.selectTool(.pen)
        canvas.keyDown(with: toolKey("a", code: 0))
        try expect(doc.state.tool == .arrow, "A did not select arrow")
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 3100, 2200, 820))
        canvas.mouseUp(with: event(.leftMouseUp, 3250, 2200, 821))
        end()
        let arrow = doc.state.note.strokes.last!
        try expect(arrow.tool == "arrow" && arrow.samples[1].point == CGPoint(x: 3250, y: 2200), "Arrow tip incorrect")
        doc.undoInk(nil)
        try expect(!doc.state.note.strokes.contains { $0.id == arrow.id }, "Arrow undo failed")
        doc.redoInk(nil)
        try expect(doc.state.note.strokes.last == arrow, "Arrow redo failed")
        let arrowFile = try NoteFile.decode(doc.data(ofType: "com.lightnote.note"))
        try expect(arrowFile.strokes.last == arrow, "Arrow save failed")
        doc.state.selectTool(.pen)
        let beforeKeyboardUndo = doc.state.note.strokes
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        let undoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 900, windowNumber: window.windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        NSApp.mainMenu?.items.forEach { $0.submenu?.update() }
        try expect(NSApp.mainMenu?.performKeyEquivalent(with: undoKey) == true, "Command-Z menu shortcut not routed")
        try expect(doc.state.note.strokes == Array(beforeKeyboardUndo.dropLast()), "Command-Z did not undo one stroke")
        let redoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 901, windowNumber: window.windowNumber, context: nil,
            characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6)!
        NSApp.mainMenu?.items.forEach { $0.submenu?.update() }
        try expect(NSApp.mainMenu?.performKeyEquivalent(with: redoKey) == true, "Command-Shift-Z not routed")
        try expect(doc.state.note.strokes == beforeKeyboardUndo, "Keyboard redo lost stroke: expected \(beforeKeyboardUndo.count), got \(doc.state.note.strokes.count)")
        let beforeHelp = doc.state.note
        canvas.keyDown(with: toolKey("/", code: 44))
        try expect(doc.state.showShortcuts, "Slash did not open shortcut help")
        doc.state.showShortcuts = false // The sheet close button and Escape dismiss this binding.
        try expect(!doc.state.showShortcuts, "Help binding did not close")
        try expect(doc.state.note == beforeHelp, "Help modified document")
        let preferencesDomain = "com.lightnote.preferences-test." + UUID().uuidString
        let preferencesDefaults = UserDefaults(suiteName: preferencesDomain)!
        defer { preferencesDefaults.removePersistentDomain(forName: preferencesDomain) }
        let settings = AppPreferences(defaults: preferencesDefaults)
        settings.penColor = .red; settings.penWidth = 3; settings.defaultPaper = .blank
        settings.palette[0] = .blue
        settings.paperColor = InkColor(0.9, 0.9, 0.8)
        settings.gridColor = .green; settings.gridSpacing = 30
        settings.automaticChecks = false; settings.automaticDownloads = false
        let restoredSettings = AppPreferences(defaults: preferencesDefaults)
        try expect(restoredSettings.penColor == .red && restoredSettings.penWidth == 3 && restoredSettings.defaultPaper == .blank,
                   "Drawing preferences did not persist")
        try expect(restoredSettings.colorPresets[0].color == .blue && restoredSettings.gridSpacing == 30 && restoredSettings.gridColor == .green,
                   "Palette and grid preferences did not persist")
        try expect(!restoredSettings.automaticChecks && !restoredSettings.automaticDownloads, "Update settings did not persist")
        let preferencesKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 950, windowNumber: window.windowNumber, context: nil,
            characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
        NSApp.mainMenu?.items.forEach { $0.submenu?.update() }
        try expect(NSApp.mainMenu?.performKeyEquivalent(with: preferencesKey) == true, "Command-comma was not routed")
        let preferencesWindow = NSApp.windows.first { $0.title == "환경설정" }
        try expect(preferencesWindow?.contentView != nil, "Preferences window not created")
        preferencesWindow?.close()
        let board = NSPasteboard(name: NSPasteboard.Name("com.lightnote.tests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        doc.state.selectTool(.selection)
        canvas.mouseDown(with: event(.leftMouseDown, 2400, 1900, 1000))
        canvas.mouseUp(with: event(.leftMouseUp, 3300, 2250, 1001))
        let beforeCopy = doc.state.note.strokes
        try expect(doc.state.hasSelection && canvas.copySelection(to: board), "Selection copy failed")
        let payload = board.data(forType: InkCanvasView.inkPasteboardType)!
        let source = try NoteFile.decode(payload).strokes
        try expect(source.count == 3 && Set(source.map(\.tool)) == Set(["rectangle", "ellipse", "arrow"]), "Copy included wrong objects")
        try expect(doc.state.note.strokes == beforeCopy, "Copy changed source")
        begin(); let pasted = canvas.pasteSelection(from: board); end()
        try expect(pasted && doc.state.note.strokes.count == beforeCopy.count+3, "Batch paste failed")
        let firstPaste = doc.state.note.strokes
        let firstIDs = Set(firstPaste.suffix(3).map(\.id))
        try expect(firstIDs.isDisjoint(with: Set(beforeCopy.map(\.id))) && doc.state.hasSelection, "Pasted IDs or selection incorrect")
        begin(); let pastedAgain = canvas.pasteSelection(from: board); end()
        let secondPaste = doc.state.note.strokes
        try expect(pastedAgain && secondPaste.count == beforeCopy.count+6, "Repeated paste failed")
        try expect(secondPaste.last!.samples[0].point != firstPaste.last!.samples[0].point, "Repeated pastes overlap")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes == firstPaste, "Paste undo did not remove one batch")
        doc.redoInk(nil)
        try expect(doc.state.note.strokes == secondPaste, "Paste redo not exact")
        doc.undoInk(nil)
        canvas.mouseDown(with: event(.leftMouseDown, 3099, 2199, 1002))
        canvas.mouseUp(with: event(.leftMouseUp, 3251, 2201, 1003))
        let duplicateKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1004, windowNumber: window.windowNumber, context: nil,
            characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)!
        begin()
        NSApp.mainMenu?.items.forEach { $0.submenu?.update() }
        try expect(NSApp.mainMenu?.performKeyEquivalent(with: duplicateKey) == true, "Command-D not routed")
        end()
        try expect(doc.state.note.strokes.count == firstPaste.count+1 && doc.state.note.strokes.last?.tool == "arrow", "Command-D did not duplicate selected arrow")
        doc.undoInk(nil)
        try expect(doc.state.note.strokes == firstPaste, "Duplicate undo failed")
        let destinationDoc = NoteDocument()
        let destinationCanvas = InkCanvasView(state: destinationDoc.state)
        destinationDoc.undoManager?.groupsByEvent = false
        destinationDoc.undoManager?.beginUndoGrouping()
        try expect(destinationCanvas.pasteSelection(from: board), "Cross-note paste failed")
        destinationDoc.undoManager?.endUndoGrouping()
        try expect(destinationDoc.state.note.strokes.count == 3, "Cross-note paste count incorrect")
        try expect(Set(destinationDoc.state.note.strokes.map(\.id)).isDisjoint(with: Set(source.map(\.id))), "Cross-note copy reused IDs")
        let clipboardSaved = try NoteFile.decode(destinationDoc.data(ofType: "com.lightnote.note"))
        try expect(clipboardSaved.strokes == destinationDoc.state.note.strokes, "Pasted objects not saved")
        board.clearContents(); board.setData(Data("broken".utf8), forType: InkCanvasView.inkPasteboardType)
        let beforeBadPaste = destinationDoc.state.note
        try expect(!destinationCanvas.pasteSelection(from: board) && destinationDoc.state.note == beforeBadPaste, "Invalid clipboard changed note")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<40 { for y in 0..<20 {
            let pixel = bitmap.bitmapData! + y*bitmap.bytesPerRow + x*4
            pixel[0] = y < 10 ? 255 : 0; pixel[1] = 0
            pixel[2] = y < 10 ? 0 : 255; pixel[3] = 255
        } }
        let png = bitmap.representation(using: .png, properties: [:])!
        board.clearContents(); board.setData(png, forType: .png)
        destinationDoc.undoManager?.beginUndoGrouping()
        try expect(destinationCanvas.pasteSelection(from: board), "PNG clipboard paste failed")
        destinationDoc.undoManager?.endUndoGrouping()
        let imageObject = destinationDoc.state.note.strokes.last!
        try expect(imageObject.tool == "image" && imageObject.imagePNG != nil && destinationDoc.state.hasSelection, "Image not selected or embedded")
        let imageSaved = try NoteFile.decode(destinationDoc.data(ofType: "com.lightnote.note"))
        try expect(imageSaved.strokes.last == imageObject, "Image persistence failed")
        destinationDoc.undoInk(nil)
        try expect(destinationDoc.state.note == beforeBadPaste, "Image paste undo failed")
        destinationDoc.redoInk(nil)
        try expect(destinationDoc.state.note.strokes.last == imageObject, "Image redo failed")
        destinationDoc.undoManager?.beginUndoGrouping()
        destinationDoc.transformStrokes(ids: [imageObject.id], using: CGAffineTransform(scaleX: 2, y: 2))
        destinationDoc.undoManager?.endUndoGrouping()
        try expect(destinationDoc.state.note.strokes.last!.imagePNG == imageObject.imagePNG && destinationDoc.state.note.strokes.last!.bounds.width > imageObject.bounds.width, "Image resize damaged payload")
        // Export a mixed selection, including an embedded image and overlapping ink.
        let selectedImage = destinationDoc.state.note.strokes.last!
        let imageA = selectedImage.samples[0].point, imageB = selectedImage.samples[1].point
        let imageRect = CGRect(x:min(imageA.x,imageB.x),y:min(imageA.y,imageB.y),width:abs(imageB.x-imageA.x),height:abs(imageB.y-imageA.y))
        let green = InkColor(0,1,0)
        let overlay = InkStroke(color:green,width:4,samples:[
            InkSample(x:imageRect.minX+4,y:imageRect.midY,time:1),
            InkSample(x:imageRect.maxX-4,y:imageRect.midY,time:2)])
        let mixed = [selectedImage,overlay]
        board.clearContents(); board.setData(try NoteFile(strokes:mixed).encoded(),forType:InkCanvasView.inkPasteboardType)
        destinationDoc.undoManager?.beginUndoGrouping()
        try expect(destinationCanvas.pasteSelection(from:board),"Mixed PNG fixture paste failed")
        destinationDoc.undoManager?.endUndoGrouping()
        let exportObjects = Array(destinationDoc.state.note.strokes.suffix(2))
        let exportImage = exportObjects[0]
        let a = exportImage.samples[0].point, b = exportImage.samples[1].point
        let exportedRect = CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y))
        let crop = exportObjects.reduce(CGRect.null){$0.union($1.bounds)}.insetBy(dx:-8,dy:-8).integral
        destinationDoc.undoManager?.beginUndoGrouping()
        destinationDoc.append(InkStroke(color:InkColor(1,0,1),width:8,samples:[InkSample(x:exportedRect.midX,y:exportedRect.minY+exportedRect.height/4,time:3)]))
        destinationDoc.undoManager?.endUndoGrouping()
        let beforePNG = destinationDoc.state.note
        let undoBeforePNG = destinationDoc.undoManager?.canUndo
        let copiedPNG = try destinationCanvas.copyPNG(to:board)
        try expect(copiedPNG,"PNG clipboard copy failed")
        let exportedPNG = board.data(forType:.png)!
        let exportedBitmap = NSBitmapImageRep(data:exportedPNG)!
        try expect(exportedBitmap.pixelsWide == Int(crop.width*2) && exportedBitmap.pixelsHigh == Int(crop.height*2),"PNG crop/resolution incorrect")
        func exportedColor(_ point:CGPoint) -> NSColor {
            exportedBitmap.colorAt(x:Int((point.x-crop.minX)*2),y:Int((point.y-crop.minY)*2))!.usingColorSpace(.deviceRGB)!
        }
        let upper = exportedColor(CGPoint(x:exportedRect.midX,y:exportedRect.minY+exportedRect.height/4))
        let lower = exportedColor(CGPoint(x:exportedRect.midX,y:exportedRect.minY+exportedRect.height*3/4))
        let middle = exportedColor(CGPoint(x:exportedRect.midX,y:exportedRect.midY))
        try expect(upper.redComponent > 0.8 && upper.blueComponent < 0.2 && lower.blueComponent > 0.8 && lower.redComponent < 0.2,
                   "Exported image was flipped or included unselected ink: upper=\(upper) lower=\(lower) middle=\(middle)")
        try expect(middle.greenComponent > 0.8 && middle.redComponent < 0.2,"PNG lost overlapping selected pen")
        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at:pngURL) }
        try destinationCanvas.writeSelectionPNG(to:pngURL)
        let diskPNG = try Data(contentsOf:pngURL)
        try expect(diskPNG == exportedPNG,"Exported file differs from PNG clipboard")
        try expect(destinationDoc.state.note == beforePNG && destinationDoc.undoManager?.canUndo == undoBeforePNG && destinationDoc.state.hasSelection,
                   "PNG export changed document/undo/selection")
        func contextEvent(_ point:CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:.rightMouseDown,location:destinationCanvas.convert(point,to:nil),modifierFlags:[],
                timestamp:1390,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:0)!
        }
        guard let contextMenu = destinationCanvas.menu(for:contextEvent(CGPoint(x:exportedRect.midX,y:exportedRect.midY))),
              contextMenu.items.map(\.title) == ["복사","생성"],
              let copyMenu = contextMenu.items[0].submenu,
              let createMenu = contextMenu.items[1].submenu else { throw Failure(message:"Selection context menu missing") }
        try expect(copyMenu.items.map(\.title) == ["PNG 클립보드 복사","PNG 파일 저장…"],"PNG context choices incorrect")
        try expect(copyMenu.items[0].target === destinationCanvas && copyMenu.items[0].action == NSSelectorFromString("contextCopyPNG:") &&
                   copyMenu.items[1].target === destinationCanvas && copyMenu.items[1].action == NSSelectorFromString("contextSavePNG:"),
                   "Context PNG actions not connected")
        try expect(destinationCanvas.menu(for:contextEvent(CGPoint(x:crop.minX-30,y:crop.minY-30))) == nil,"Context menu opened outside selection")
        let beforeContextStickers = Set(StickerLibrary.shared.stickers.map(\.id))
        createMenu.performActionForItem(at:0)
        let createdContextStickers = StickerLibrary.shared.stickers.filter{!beforeContextStickers.contains($0.id)}
        try expect(createdContextStickers.count == 1 && destinationDoc.state.showStickers,"Context sticker creation failed")
        let createdContextPNG = try StickerLibrary.shared.data(for:createdContextStickers[0])
        try expect(createdContextPNG == exportedPNG && destinationDoc.state.note == beforePNG,"Context sticker changed note or rendered different content")
        try StickerLibrary.shared.remove(createdContextStickers[0])
        destinationDoc.state.showStickers = false
        let lockedIDs = Set(exportObjects.map(\.id))
        let lockBitmap = destinationCanvas.bitmapImageRepForCachingDisplay(in:destinationCanvas.bounds)!
        destinationCanvas.cacheDisplay(in:destinationCanvas.bounds,to:lockBitmap)
        guard let lockButton = destinationCanvas.subviews.compactMap({$0 as? NSButton}).first else {
            throw Failure(message:"Selection lock button missing")
        }
        try expect(!lockButton.isHidden,"Selection lock button hidden")
        let buttonPreview = lockButton.bitmapImageRepForCachingDisplay(in:lockButton.bounds)!
        lockButton.cacheDisplay(in:lockButton.bounds,to:buttonPreview)
        try buttonPreview.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/lightnote-lock-button-preview.png"))
        let center = buttonPreview.colorAt(x:buttonPreview.pixelsWide/2,y:buttonPreview.pixelsHigh/2)!.usingColorSpace(.deviceRGB)!
        try expect(center.alphaComponent > 0.95,"Lock button has no opaque background")
        destinationDoc.undoManager?.beginUndoGrouping()
        lockButton.performClick(nil)
        destinationDoc.undoManager?.endUndoGrouping()
        let lockedNote = destinationDoc.state.note
        try expect(lockedNote.strokes.filter{lockedIDs.contains($0.id)}.allSatisfy(\.isLocked),"Lock button did not lock selected objects")
        destinationDoc.moveStrokes(ids:lockedIDs,by:CGSize(width:40,height:30))
        destinationDoc.transformStrokes(ids:lockedIDs,using:CGAffineTransform(scaleX:2,y:2))
        destinationDoc.eraseStrokes(ids:lockedIDs)
        try expect(destinationDoc.state.note == lockedNote,"Locked objects moved/resized/deleted")
        let savedLocked = try NoteFile.decode(destinationDoc.data(ofType:"com.lightnote.note"))
        try expect(savedLocked == lockedNote,"Lock did not survive save")
        destinationDoc.undoInk(nil)
        try expect(destinationDoc.state.note == beforePNG,"Lock undo failed")
        destinationDoc.redoInk(nil)
        try expect(destinationDoc.state.note == lockedNote,"Lock redo failed")
        destinationDoc.undoManager?.beginUndoGrouping()
        lockButton.performClick(nil)
        destinationDoc.undoManager?.endUndoGrouping()
        try expect(destinationDoc.state.note == beforePNG,"Unlock button failed")
        destinationCanvas.cacheDisplay(in:destinationCanvas.bounds,to:lockBitmap)
        let buttonBeforeDrag = lockButton.frame
        func selectionDragEvent(_ type:NSEvent.EventType,_ point:CGPoint,_ time:Double) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:destinationCanvas.convert(point,to:nil),modifierFlags:[],timestamp:time,
                windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:0)!
        }
        let dragStart = CGPoint(x:exportedRect.midX,y:exportedRect.midY)
        let dragEnd = CGPoint(x:dragStart.x+40,y:dragStart.y+25)
        destinationDoc.undoManager?.beginUndoGrouping()
        destinationCanvas.mouseDown(with:selectionDragEvent(.leftMouseDown,dragStart,1400))
        destinationCanvas.mouseDragged(with:selectionDragEvent(.leftMouseDragged,dragEnd,1401))
        try expect(abs(lockButton.frame.minX-buttonBeforeDrag.minX-40) < 0.01 && abs(lockButton.frame.minY-buttonBeforeDrag.minY-25) < 0.01,
                   "Lock button did not follow live selection drag")
        try expect(lockButton.frame.size == CGSize(width:36,height:26),"Lock button size was not reduced")
        destinationCanvas.mouseUp(with:selectionDragEvent(.leftMouseUp,dragEnd,1402))
        destinationDoc.undoManager?.endUndoGrouping()
        destinationCanvas.cacheDisplay(in:destinationCanvas.bounds,to:lockBitmap)
        try expect(abs(lockButton.frame.minX-buttonBeforeDrag.minX-40) < 0.01 && abs(lockButton.frame.minY-buttonBeforeDrag.minY-25) < 0.01,
                   "Lock button jumped after move commit")
        destinationDoc.updateChangeCount(.changeCleared); destinationDoc.close()
        canvas.keyDown(with: toolKey("q", code: 12))
        try expect(doc.state.tool == .freeArrow, "Q did not select free arrow")
        let freeBefore = doc.state.note.strokes
        begin()
        canvas.mouseDown(with: event(.leftMouseDown, 3000, 2050, 1100))
        for (i,p) in [CGPoint(x:3020,y:2010),CGPoint(x:3080,y:1990),CGPoint(x:3140,y:2030),CGPoint(x:3190,y:2100)].enumerated() {
            canvas.mouseDragged(with: event(.leftMouseDragged,p.x,p.y,1101+Double(i)))
        }
        canvas.mouseUp(with:event(.leftMouseUp,3230,2150,1106)); end()
        let free = doc.state.note.strokes.last!
        try expect(free.tool == "freeArrow" && free.samples.count == 6 && free.freeArrowHead.count == 3, "Free arrow lost curve or head")
        let freeSaved = try NoteFile.decode(doc.data(ofType:"com.lightnote.note"))
        try expect(freeSaved.strokes.last == free, "Free arrow save failed")
        doc.undoInk(nil); try expect(doc.state.note.strokes == freeBefore, "Free arrow not one undo action")
        doc.redoInk(nil); try expect(doc.state.note.strokes.last == free, "Free arrow redo failed")
        canvas.keyDown(with:toolKey("v",code:9)); canvas.keyDown(with:toolKey("\u{1b}",code:53))
        let wing = free.freeArrowHead[0], tip = free.freeArrowHead[1]
        let hit = CGPoint(x:(wing.x+tip.x)/2,y:(wing.y+tip.y)/2)
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,hit.x-0.5,hit.y-0.5,1110))
        canvas.mouseDragged(with:event(.leftMouseDragged,hit.x+0.5,hit.y+0.5,1111))
        canvas.mouseUp(with:event(.leftMouseUp,hit.x+0.5,hit.y+0.5,1112)); end()
        try expect(doc.state.hasSelection, "Arrowhead could not be selected")
        begin(); canvas.keyDown(with:toolKey("\u{7f}",code:51)); end()
        try expect(!doc.state.note.strokes.contains{$0.id == free.id}, "Selected free arrow delete failed")
        doc.undoInk(nil); try expect(doc.state.note.strokes.last == free, "Free arrow deletion undo failed")
        canvas.keyDown(with: toolKey("p",code:35))
        func shiftFlags(_ down: Bool) -> NSEvent {
            let raw = CGEvent(keyboardEventSource:nil,virtualKey:56,keyDown:down)!
            raw.type = .flagsChanged; raw.flags = down ? .maskShift : []
            return NSEvent(cgEvent:raw)!
        }
        let beforeLine = doc.state.note.strokes
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,3000,1800,1200,modifiers:.shift))
        canvas.mouseDragged(with:event(.leftMouseDragged,3020,1740,1201,modifiers:.shift))
        canvas.mouseDragged(with:event(.leftMouseDragged,3100,1900,1202,modifiers:.shift))
        try expect(canvas.displayedStroke?.samples.count == 2, "Shift pen preview is not straight")
        canvas.flagsChanged(with:shiftFlags(false))
        try expect(canvas.displayedStroke?.samples.count == 3, "Shift release did not restore free preview")
        canvas.flagsChanged(with:shiftFlags(true))
        try expect(canvas.displayedStroke?.samples.count == 2, "Shift press without mouse movement did not constrain")
        canvas.mouseUp(with:event(.leftMouseUp,3150,1870,1203,modifiers:.shift)); end()
        let line = doc.state.note.strokes.last!
        try expect(line.tool == "pen" && line.samples.count == 2 && line.samples.first!.point == CGPoint(x:3000,y:1800) && line.samples.last!.point == CGPoint(x:3150,y:1870), "Shift line lost anchored endpoints")
        let savedLine = try NoteFile.decode(doc.data(ofType:"com.lightnote.note"))
        try expect(savedLine.strokes.last == line, "Shift line save failed")
        doc.undoInk(nil); try expect(doc.state.note.strokes == beforeLine,"Shift line undo not atomic")
        doc.redoInk(nil); try expect(doc.state.note.strokes.last == line,"Shift line redo failed")
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,3000,1800,1210))
        canvas.mouseDragged(with:event(.leftMouseDragged,3020,1740,1211))
        canvas.mouseDragged(with:event(.leftMouseDragged,3100,1900,1212))
        canvas.flagsChanged(with:shiftFlags(true))
        try expect(canvas.displayedStroke?.samples.count == 2,"Mid-stroke Shift did not straighten")
        canvas.mouseUp(with:event(.leftMouseUp,3150,1870,1213,modifiers:.shift)); end()
        try expect(doc.state.note.strokes.last!.samples.count == 2,"Mid-stroke line was not committed straight")
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,3000,1800,1220,modifiers:.shift))
        canvas.mouseDragged(with:event(.leftMouseDragged,3020,1740,1221,modifiers:.shift))
        canvas.flagsChanged(with:shiftFlags(false))
        canvas.mouseDragged(with:event(.leftMouseDragged,3100,1900,1222))
        canvas.mouseUp(with:event(.leftMouseUp,3150,1870,1223)); end()
        try expect(doc.state.note.strokes.last!.samples.count == 4,"Released Shift pen remained constrained")
        canvas.keyDown(with:toolKey("q",code:12))
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,3000,1800,1230,modifiers:.shift))
        canvas.mouseDragged(with:event(.leftMouseDragged,3020,1740,1231,modifiers:.shift))
        canvas.mouseDragged(with:event(.leftMouseDragged,3100,1900,1232,modifiers:.shift))
        canvas.mouseUp(with:event(.leftMouseUp,3150,1870,1233,modifiers:.shift)); end()
        try expect(doc.state.note.strokes.last!.tool == "freeArrow" && doc.state.note.strokes.last!.samples.count == 4,"Shift changed Q free arrow behavior")
        doc.state.selectTool(.pen)
        func commandFlags(_ down: Bool) -> NSEvent {
            let raw = CGEvent(keyboardEventSource:nil,virtualKey:55,keyDown:down)!
            raw.type = .flagsChanged; raw.flags = down ? .maskCommand : []
            return NSEvent(cgEvent:raw)!
        }
        let countBeforeCommand = doc.state.note.strokes.count
        canvas.flagsChanged(with:commandFlags(true))
        try expect(doc.state.tool == .selection,"Command did not select")
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,2990,1730,1240,modifiers:.command))
        canvas.mouseDragged(with:event(.leftMouseDragged,3160,1910,1241,modifiers:.command))
        canvas.flagsChanged(with:commandFlags(false))
        try expect(doc.state.tool == .selection,"Command release interrupted selection drag")
        canvas.mouseUp(with:event(.leftMouseUp,3160,1910,1242)); end()
        try expect(doc.state.tool == .selection && doc.state.hasSelection && doc.state.note.strokes.count == countBeforeCommand,
                   "Command selection did not persist or added ink")
        doc.state.selectTool(.eraser)
        canvas.flagsChanged(with:commandFlags(true))
        canvas.flagsChanged(with:commandFlags(false))
        try expect(doc.state.tool == .eraser,"Empty Command selection did not restore eraser")
        doc.state.selectTool(.pen)
        canvas.flagsChanged(with:commandFlags(true))
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,10,10,1250,modifiers:.command))
        canvas.mouseDragged(with:event(.leftMouseDragged,11,11,1251,modifiers:.command))
        canvas.mouseUp(with:event(.leftMouseUp,11,11,1252,modifiers:.command)); end()
        try expect(doc.state.tool == .pen && !doc.state.hasSelection,"Empty marquee did not restore pen")
        canvas.flagsChanged(with:commandFlags(false))
        doc.state.selectTool(.selection)
        canvas.flagsChanged(with:commandFlags(true))
        canvas.flagsChanged(with:commandFlags(false))
        try expect(doc.state.tool == .selection,"Command changed persistent V selection")
        canvas.keyDown(with:toolKey("p",code:35))
        try expect(doc.state.tool == .pen,"P did not leave Command selection")
        doc.state.selectTool(.ellipse)
        canvas.flagsChanged(with:commandFlags(true))
        try expect(doc.state.tool == .ellipse,"Command broke constrained shape tool")
        canvas.flagsChanged(with:commandFlags(false))
        doc.state.selectTool(.pen)
        func tabletEvent(_ type: NSEvent.EventType, _ x: Double, _ y: Double,
                         _ time: Double, pressure: Double) -> NSEvent {
            let raw = event(type,x,y,time).cgEvent!.copy()!
            raw.setIntegerValueField(.mouseEventSubtype,value:1)
            raw.setDoubleValueField(.tabletEventPointPressure,value:pressure)
            return NSEvent(cgEvent:raw)!
        }
        let contact = tabletEvent(.leftMouseDragged,3100,1800,1301,pressure:0.5)
        try expect(contact.subtype == .tabletPoint && contact.pressure > 0,"Tablet fixture lost pressure")
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,3000,1800,1300))
        canvas.mouseDragged(with:contact)
        canvas.mouseDragged(with:tabletEvent(.leftMouseDragged,3110,1810,1302,pressure:0))
        canvas.mouseUp(with:event(.leftMouseUp,3120,1820,1303)); end()
        let tabletStroke = doc.state.note.strokes.last!
        try expect(tabletStroke.samples.count == 2 && tabletStroke.samples.last!.point == CGPoint(x:3100,y:1800),
                   "Tablet lift appended a hover tail")
        begin()
        canvas.mouseDown(with:event(.leftMouseDown,3000,1800,1310))
        canvas.mouseDragged(with:event(.leftMouseDragged,3100,1800,1311))
        canvas.mouseUp(with:event(.leftMouseUp,3120,1820,1312)); end()
        try expect(doc.state.note.strokes.last!.samples.last!.point == CGPoint(x:3120,y:1820),
                   "Tablet filtering truncated an ordinary mouse endpoint")
        let pageDoc = NoteDocument()
        let pageCanvas = InkCanvasView(state:pageDoc.state)
        pageDoc.undoManager?.groupsByEvent = false
        let pageHeight = pageDoc.state.note.pageHeight
        try expect(pageCanvas.frame.height == pageHeight && pageDoc.state.workspacePageCount == 1,"Blank note created extra page")
        func pageEvent(_ type:NSEvent.EventType,_ y:Double,_ time:Double) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:pageCanvas.convert(CGPoint(x:100,y:y),to:nil),modifierFlags:[],timestamp:time,windowNumber:0,
                context:nil,eventNumber:0,clickCount:1,pressure:0)!
        }
        pageDoc.undoManager?.beginUndoGrouping()
        pageCanvas.mouseDown(with:pageEvent(.leftMouseDown,pageHeight-20,1500))
        pageCanvas.mouseDragged(with:pageEvent(.leftMouseDragged,pageHeight+20,1501))
        pageCanvas.mouseUp(with:pageEvent(.leftMouseUp,pageHeight+40,1502))
        pageDoc.undoManager?.endUndoGrouping()
        try expect(pageDoc.state.workspacePageCount == 2 && pageCanvas.frame.height == pageHeight*2,"Crossing lower boundary did not append a full page")
        try expect(pageDoc.state.note.strokes.count == 1 && pageDoc.state.note.strokes[0].samples.count == 3,"Page boundary split a stroke")
        let guideRect = CGRect(x:0,y:pageHeight-30,width:300,height:100)
        let guideBitmap = pageCanvas.bitmapImageRepForCachingDisplay(in:guideRect)!
        pageCanvas.cacheDisplay(in:guideRect,to:guideBitmap)
        try guideBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/lightnote-pages-preview.png"))
        let pagesSaved = try pageDoc.data(ofType:"com.lightnote.note")
        let reopenedPages = NoteDocument()
        try reopenedPages.read(from:pagesSaved,ofType:"com.lightnote.note")
        let reopenedCanvas = InkCanvasView(state:reopenedPages.state)
        try expect(reopenedCanvas.frame.height == pageHeight*2 && reopenedPages.state.note == pageDoc.state.note,"Pages/ink did not survive reopening")
        let nearBoundaryDoc = NoteDocument()
        let nearBoundaryNote = NoteFile(strokes:[InkStroke(samples:[InkSample(x:100,y:pageHeight-10,time:1)])])
        try nearBoundaryDoc.read(from:nearBoundaryNote.encoded(),ofType:"com.lightnote.note")
        let nearBoundaryCanvas = InkCanvasView(state:nearBoundaryDoc.state)
        try expect(nearBoundaryCanvas.frame.height == pageHeight,"Reopening near the boundary added a spurious page")
        nearBoundaryDoc.updateChangeCount(.changeCleared); nearBoundaryDoc.close()
        pageDoc.updateChangeCount(.changeCleared); pageDoc.close()
        reopenedPages.updateChangeCount(.changeCleared); reopenedPages.close()
        let stickersFolder = FileManager.default.temporaryDirectory.appendingPathComponent("LightNote-stickers-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:stickersFolder) }
        let stickerLibrary = StickerLibrary(directory:stickersFolder)
        let sticker = try stickerLibrary.add(data:png,name:"테스트")
        let duplicateSticker = try stickerLibrary.add(data:png,name:"테스트")
        try expect(sticker.id != duplicateSticker.id && stickerLibrary.stickers.count == 2,"Sticker registration overwrote an existing item")
        let reopenedLibrary = StickerLibrary(directory:stickersFolder)
        try expect(reopenedLibrary.stickers.count == 2 && reopenedLibrary.stickers.allSatisfy{$0.thumbnail.size.width > 0},"Sticker library did not survive reload")
        do {
            _ = try stickerLibrary.add(data:Data("invalid image".utf8),name:"잘못된 이미지")
            throw Failure(message:"Invalid sticker was accepted")
        } catch is Failure { throw Failure(message:"Invalid sticker was accepted") }
          catch { /* Expected validation error. */ }
        try expect(stickerLibrary.stickers.count == 2,"Invalid sticker changed library")
        let stickerDoc = NoteDocument()
        let stickerCanvas = InkCanvasView(state:stickerDoc.state)
        stickerDoc.undoManager?.groupsByEvent = false
        let stickerData = try stickerLibrary.data(for:sticker)
        stickerDoc.undoManager?.beginUndoGrouping()
        try expect(stickerCanvas.insertSticker(stickerData),"Sticker insertion failed")
        stickerDoc.undoManager?.endUndoGrouping()
        let insertedSticker = stickerDoc.state.note.strokes[0]
        try expect(insertedSticker.tool == "image" && insertedSticker.imagePNG == png && stickerDoc.state.hasSelection,
                   "Inserted sticker lost image or selection")
        stickerDoc.undoInk(nil)
        try expect(stickerDoc.state.note.strokes.isEmpty,"Sticker insert undo failed")
        stickerDoc.redoInk(nil)
        try expect(stickerDoc.state.note.strokes == [insertedSticker],"Sticker insert redo failed")
        stickerDoc.undoManager?.beginUndoGrouping()
        try expect(stickerCanvas.insertSticker(stickerData),"Repeated sticker insertion failed")
        stickerDoc.undoManager?.endUndoGrouping()
        try expect(Set(stickerDoc.state.note.strokes.map(\.id)).count == 2,"Repeated sticker reused object ID")
        let savedStickers = try NoteFile.decode(stickerDoc.data(ofType:"com.lightnote.note"))
        try stickerLibrary.remove(sticker)
        try expect(stickerLibrary.stickers.count == 1 && savedStickers.strokes.allSatisfy{$0.imagePNG == png},
                   "Deleting library item changed embedded stickers")
        let jpegData = NSMutableData()
        let jpegDestination = CGImageDestinationCreateWithData(jpegData,"public.jpeg" as CFString,1,nil)!
        CGImageDestinationAddImage(jpegDestination,NSBitmapImageRep(data:png)!.cgImage!,[kCGImagePropertyOrientation:6] as CFDictionary)
        try expect(CGImageDestinationFinalize(jpegDestination),"Oriented JPEG fixture failed")
        let rotatedSticker = try stickerLibrary.add(data:jpegData as Data,name:"회전 이미지")
        let rotatedBitmap = NSBitmapImageRep(data:try stickerLibrary.data(for:rotatedSticker))!
        try expect(rotatedBitmap.pixelsWide == 20 && rotatedBitmap.pixelsHigh == 40,"Sticker import ignored image orientation")
        for x in 0..<20 { for y in 0..<20 {
            let pixel = bitmap.bitmapData! + y*bitmap.bytesPerRow+x*4
            pixel[0] = 0; pixel[1] = 0; pixel[2] = 0; pixel[3] = 0
        } }
        let transparentPNG = bitmap.representation(using:.png,properties:[:])!
        let transparentSticker = try stickerLibrary.add(data:transparentPNG,name:"투명 스티커")
        let transparentSaved = try stickerLibrary.data(for:transparentSticker)
        try expect(transparentSaved == transparentPNG && NSBitmapImageRep(data:transparentSaved)!.colorAt(x:5,y:5)!.alphaComponent == 0,
                   "Transparent sticker lost its alpha channel")
        stickerDoc.updateChangeCount(.changeCleared); stickerDoc.close()
        print("Verified: Shift pen line/press/release/mid-stroke/undo/redo/save; Q free-arrow drawing/head-selection/delete/undo/redo/save; 100 taps; 2002-sample stroke; mid-stroke save continuity; style; undo/redo; interruption; dot pixels; grid pixels/style undo/redo; stroke eraser click/sweep/undo/redo/keys; rectangle selection/move/undo/redo/save; zoom transforms/ink/eraser/reset; outer viewport grid/input/reopen; shapes/command circle/corner resize/undo/redo; laser hold/release/expiry/non-persistence; managed note automatic save/reopen; disk roundtrip; corrupt read")
        doc.updateChangeCount(.changeCleared)
        doc.close()
    }
}


extension AppSelfTest {
    /// Synthetic save workload only: does not open or modify personal documents.
    static func benchmarkSaving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LightNote-save-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        @MainActor final class Heartbeat {
            var last = ProcessInfo.processInfo.systemUptime
            var maxGap = 0.0
            func tick() {
                let now = ProcessInfo.processInfo.systemUptime
                maxGap = max(maxGap, now-last); last = now
            }
            func reset() { last = ProcessInfo.processInfo.systemUptime; maxGap = 0 }
        }
        let beat = Heartbeat()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated { beat.tick() }
        }
        defer { timer.invalidate() }
        let applied = CommandLine.arguments.contains("--save-benchmark-applied")
        print("SAVE_BENCHMARK optimized=\(!_isDebugAssertConfiguration()) heartbeat_ms=5 samples_per_stroke=100 repeats=3")
        print("strokes,bytes,mode,run,elapsed_ms,max_main_gap_ms")
        for count in [1000, 10000, 20000] {
            let doc = NoteDocument()
            doc.state.note.strokes = (0..<count).map { i in
                InkStroke(samples: (0..<100).map { j in
                    InkSample(x: Double(i%100)*6+Double(j)*0.2,
                              y: Double(i/100)*4+sin(Double(j)*0.1)*10,
                              time: Double(i)+Double(j)*0.001, pressure: 0.5)
                })
            }
            for run in 1...3 {
                for mode in (applied ? ["appkit_async"] : ["main_encode", "main_safe_save", "background_prototype"]) {
                    try await Task.sleep(for: .milliseconds(20))
                    beat.reset()
                    let start = ProcessInfo.processInfo.systemUptime
                    let bytes: Int
                    if mode == "main_encode" {
                        bytes = try doc.data(ofType: "com.lightnote.note").count
                    } else if mode == "main_safe_save" {
                        try doc.persistNow(directory: directory)
                        bytes = try doc.fileURL!.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                    } else if mode == "appkit_async" {
                        try await doc.persistLatest(directory: directory)
                        bytes = try doc.fileURL!.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                    } else {
                        let snapshot = doc.state.note
                        let url = directory.appendingPathComponent("prototype.lightnote")
                        let worker = Task.detached(priority: .utility) {
                            let data = try snapshot.encoded()
                            try data.write(to: url, options: .atomic)
                            return data.count
                        }
                        bytes = try await worker.value
                    }
                    let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
                    try await Task.sleep(for: .milliseconds(15))
                    print(String(format: "%d,%d,%@,%d,%.2f,%.2f", count, bytes, mode, run, elapsed, beat.maxGap*1000))
                }
            }
            // Prove value snapshots do not acquire later input while a worker owns them.
            let snapshot = doc.state.note
            let url = directory.appendingPathComponent("concurrent.lightnote")
            let worker = Task.detached(priority: .utility) {
                let data = try snapshot.encoded()
                try data.write(to: url, options: .atomic)
            }
            let extra = InkStroke(samples: [InkSample(x: 12, y: 34, time: 99)])
            doc.state.note.strokes.append(extra)
            try await worker.value
            let saved = try NoteFile.decode(Data(contentsOf: url))
            guard saved == snapshot, doc.state.note.strokes.count == count+1 else {
                throw Failure(message: "Concurrent snapshot changed or later input lost")
            }
            try doc.persistNow(directory: directory)
            let latest = try NoteFile.decode(Data(contentsOf: doc.fileURL!))
            guard latest == doc.state.note else { throw Failure(message: "Latest save omitted input") }
            doc.updateChangeCount(.changeCleared); doc.close()
            print("SNAPSHOT_CHECK_PASSED strokes=\(count)")
        }
        print("SAVE_BENCHMARK_PASSED")
    }
}


@MainActor
private final class SaveCloseProbe: NSObject {
    var allowed: Bool?
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        allowed = shouldClose
    }
}

extension AppSelfTest {
    static func testBackgroundSaving() async throws {
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !value() { throw Failure(message: message) }
        }
        func waitFor(_ label: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<1000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw Failure(message: "Timed out waiting for asynchronous save: \(label)")
        }
        final class Gate: Sendable {
            let started = OSAllocatedUnfairLock(initialState: false)
            let threads = OSAllocatedUnfairLock(initialState: [Bool]())
            let counts = OSAllocatedUnfairLock(initialState: [Int]())
            let release = DispatchSemaphore(value: 0)
            func observe(_ note: NoteFile, _ main: Bool) throws {
                threads.withLock { $0.append(main) }
                let first = counts.withLock { counts in counts.append(note.strokes.count); return counts.count == 1 }
                if first {
                    started.withLock { $0 = true }
                    if release.wait(timeout: .now()+10) == .timedOut {
                        throw Failure(message: "Save test gate timed out")
                    }
                }
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightNote-async-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let oldDelay = NSDocumentController.shared.autosavingDelay
        NSDocumentController.shared.autosavingDelay = 60
        defer { NSDocumentController.shared.autosavingDelay = oldDelay }
        var documents: [NoteDocument] = []
        defer {
            for doc in documents {
                doc.observeSavesForTesting(nil)
                doc.updateChangeCount(.changeCleared); doc.close()
            }
        }
        func makeDocument() throws -> NoteDocument {
            let doc = NoteDocument()
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.undoManager?.groupsByEvent = false
            try doc.persistNow(directory: folder)
            documents.append(doc)
            return doc
        }
        func edit(_ doc: NoteDocument, _ x: Double) {
            doc.undoManager?.beginUndoGrouping()
            doc.append(InkStroke(samples: [InkSample(x: x, y: 10, time: x)]))
            doc.undoManager?.endUndoGrouping()
        }
        func disk(_ doc: NoteDocument) throws -> NoteFile {
            try NoteFile.decode(Data(contentsOf: doc.fileURL!))
        }
        let untitled = NoteDocument()
        NSDocumentController.shared.addDocument(untitled)
        documents.append(untitled)
        let initialThreads = OSAllocatedUnfairLock(initialState: [Bool]())
        untitled.observeSavesForTesting { _, main in initialThreads.withLock { $0.append(main) } }
        untitled.state.note.strokes = [InkStroke(samples: [InkSample(x: 1, y: 2, time: 3)])]
        try await untitled.persistLatest(directory: folder)
        try check(try disk(untitled) == untitled.state.note, "Initial asynchronous contents mismatch")
        try check(untitled.fileURL?.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
                  "Initial asynchronous assignment escaped isolated directory")
        try check(initialThreads.withLock { !$0.isEmpty && $0.allSatisfy { !$0 } }, "Initial save encoded on main thread")
        untitled.observeSavesForTesting(nil)
        let doc = try makeDocument()
        edit(doc, 1)
        try check(doc.hasUnautosavedChanges, "AppKit did not mark completed undo group dirty (manager=\(doc.undoManager != nil), canUndo=\(doc.undoManager?.canUndo ?? false))")
        let firstSnapshot = doc.state.note
        let gate = Gate()
        defer { gate.release.signal() }
        doc.observeSavesForTesting { try gate.observe($0, $1) }
        let saving = Task { try await doc.autosave(withImplicitCancellability: false) }
        try await waitFor("snapshot") { gate.started.withLock { $0 } }
        // This executes on the main actor while the writing thread is held open.
        edit(doc, 2)
        doc.undoManager?.beginUndoGrouping()
        doc.moveStrokes(ids: [firstSnapshot.strokes[0].id], by: CGSize(width: 3, height: 4))
        doc.undoManager?.endUndoGrouping()
        gate.release.signal()
        try await saving.value
        try check(try disk(doc) == firstSnapshot, "Autosave changed immutable snapshot")
        try check(doc.hasUnautosavedChanges, "Old autosave cleared newer input")
        try check(gate.threads.withLock { !$0.isEmpty && $0.allSatisfy { !$0 } }, "Autosave encoded on main thread")
        try await doc.persistLatest()
        try check(try disk(doc) == doc.state.note && !doc.hasUnautosavedChanges, "Latest flush lost input")

        edit(doc, 999)
        doc.undoInk(nil)
        try check(!doc.hasUnautosavedChanges, "Undo to saved contents remained dirty")
        doc.redoInk(nil)
        try check(doc.hasUnautosavedChanges, "Redo failed to mark changes dirty")
        doc.undoInk(nil)
        let ordered = Gate()
        defer { ordered.release.signal() }
        doc.observeSavesForTesting { try ordered.observe($0, $1) }
        edit(doc, 3)
        let earlier = Task { try await doc.persistLatest() }
        try await waitFor("ordered") { ordered.started.withLock { $0 } }
        edit(doc, 4)
        // AppKit can synchronously wait for an earlier activity at save entry.
        // Release off-main so this test also catches any main-queue deadlock.
        DispatchQueue.global().asyncAfter(deadline: .now()+0.1) { ordered.release.signal() }
        let later = Task { try await doc.persistLatest() }
        try await earlier.value; try await later.value
        try check(try disk(doc) == doc.state.note, "Earlier save overwrote later input")
        try check(ordered.counts.withLock { $0.first == 3 && $0.last == 4 && $0 == $0.sorted() }, "Writes were out of order")

        let closing = Gate()
        defer { closing.release.signal() }
        doc.observeSavesForTesting { try closing.observe($0, $1) }
        edit(doc, 5)
        let beforeClose = Task { try await doc.autosave(withImplicitCancellability: false) }
        try await waitFor("closing-save") { closing.started.withLock { $0 } }
        edit(doc, 6)
        let probe = SaveCloseProbe()
        DispatchQueue.global().asyncAfter(deadline: .now()+0.1) { closing.release.signal() }
        // Dispatch like an AppKit menu/window event, outside an executing Swift task.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                doc.canClose(withDelegate: probe, shouldClose: #selector(SaveCloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            }
        }
        try await waitFor("close-callback") { probe.allowed != nil }
        try await beforeClose.value
        try check(probe.allowed == true && (try disk(doc)) == doc.state.note, "Close approved before latest input saved")
        doc.observeSavesForTesting(nil)

        // Simulate quit/relaunch through the exact shared production flush path.
        let other = try makeDocument()
        edit(doc, 7); edit(other, 20)
        let quitting = Gate()
        defer { quitting.release.signal() }
        other.observeSavesForTesting { try quitting.observe($0, $1) }
        let delegate = NSApp.delegate as! AppDelegate
        let quitFlush = Task { try await delegate.flushDocumentsBeforeExit() }
        try await waitFor("quit-flush") { quitting.started.withLock { $0 } }
        edit(doc, 8) // The first document was saved before the second one began.
        quitting.release.signal()
        try await quitFlush.value
        try check(try disk(doc) == doc.state.note && (try disk(other)) == other.state.note, "Quit flush omitted edits across documents")
        try check(!doc.hasUnautosavedChanges && !other.hasUnautosavedChanges, "Quit flush left unsaved changes")
        other.observeSavesForTesting(nil)

        let previous = try Data(contentsOf: doc.fileURL!)
        edit(doc, 9)
        doc.observeSavesForTesting { _, _ in throw CocoaError(.fileWriteUnknown) }
        do {
            try await delegate.flushDocumentsBeforeExit()
            throw Failure(message: "Failed save permitted quit flush")
        } catch is CocoaError { }
        try check(doc.hasUnautosavedChanges, "Failed save cleared dirty state")
        try check(try Data(contentsOf: doc.fileURL!) == previous, "Failed save damaged previous file")
        doc.observeSavesForTesting(nil)
        do {
            try await doc.save(to: folder.appendingPathComponent("missing/child/note.lightnote"), ofType: "com.lightnote.note", for: .saveToOperation)
            throw Failure(message: "Missing-parent write unexpectedly succeeded")
        } catch is CocoaError { }
        try check(doc.hasUnautosavedChanges && (try Data(contentsOf: doc.fileURL!)) == previous, "Filesystem error lost original or dirty state")
        try await delegate.flushDocumentsBeforeExit()
        try check(try disk(doc) == doc.state.note, "Retry after write failure did not save")

        // Verify the actual scheduled autosave timer, not just explicit save calls.
        NSDocumentController.shared.autosavingDelay = 0.05
        let automatic = try makeDocument()
        edit(automatic, 30)
        try await waitFor("scheduled-timer") { !automatic.hasUnautosavedChanges }
        try check(try disk(automatic) == automatic.state.note, "Scheduled autosave did not persist input")
        print("BACKGROUND_SAVE_TESTS_PASSED snapshot/new-input/dirty-token/ordered-writes/close/quit-multiple-documents/write-failure/retry/scheduled-autosave")
    }
}


extension AppSelfTest {
    /// Runs in a disposable subprocess because success actually terminates NSApp.
    static func prepareQuitSavingTest() async throws {
        guard CommandLine.arguments.contains("--self-test"),
              let directory = ProcessInfo.processInfo.environment["LIGHTNOTE_TEST_DIRECTORY"] else { throw Failure(message: "Missing isolated lifecycle directory") }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let doc = NoteDocument()
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.undoManager?.groupsByEvent = false
        try doc.persistNow(directory: folder)
        let original = try Data(contentsOf: doc.fileURL!)
        func edit(_ x: Double) {
            doc.undoManager?.beginUndoGrouping()
            doc.append(InkStroke(samples: [InkSample(x: x, y: 5, time: x)]))
            doc.undoManager?.endUndoGrouping()
        }
        edit(1)
        if CommandLine.arguments.contains("--fail-save") {
            doc.observeSavesForTesting { _, _ in throw CocoaError(.fileWriteUnknown) }
            let delegate = NSApp.delegate as! AppDelegate
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            for _ in 0..<1000 {
                if !delegate.terminationPending {
                    guard doc.hasUnautosavedChanges, doc.state.note.strokes.count == 1,
                          try Data(contentsOf: doc.fileURL!) == original else { throw Failure(message: "Quit failure lost content") }
                    print("QUIT_FAILURE_CANCELLED_AND_CONTENT_PRESERVED")
                    doc.observeSavesForTesting(nil)
                    doc.updateChangeCount(.changeCleared); doc.close()
                    exit(0)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw Failure(message: "Quit was not cancelled after write failure")
        }
        let started = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        doc.observeSavesForTesting { _, _ in
            let first = started.withLock { value in let first = !value; value = true; return first }
            if first, gate.wait(timeout: .now()+10) == .timedOut { throw Failure(message: "Quit gate timed out") }
        }
        let pending = Task { try await doc.autosave(withImplicitCancellability: false) }
        for _ in 0..<1000 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard started.withLock({ $0 }) else { throw Failure(message: "No in-flight autosave") }
        edit(2)
        try doc.state.note.encoded().write(to: folder.appendingPathComponent("expected.json"))
        DispatchQueue.global().asyncAfter(deadline: .now()+0.1) { gate.signal() }
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        try await pending.value
        // Keep the subprocess alive for the asynchronous termination reply.
        try await Task.sleep(for: .seconds(15))
        throw Failure(message: "Application did not terminate after saving")
    }
}


extension AppSelfTest {
    static func testExternalConflicts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightNote-conflict-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("lesson.lightnote")
        let base = NoteFile(strokes:[InkStroke(samples:[InkSample(x:1,y:1,time:1)])])
        try base.encoded().write(to:source)
        let doc = try NoteDocument(contentsOf:source,ofType:"com.lightnote.note")
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.undoManager?.groupsByEvent=false
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.undoManager?.beginUndoGrouping()
        doc.append(InkStroke(samples:[InkSample(x:2,y:2,time:2)]))
        doc.undoManager?.endUndoGrouping()
        let local = doc.state.note
        let external = NoteFile(strokes:[InkStroke(color:.red,samples:[InkSample(x:50,y:50,time:50)])])
        let before = Set((try? FileManager.default.contentsOfDirectory(at:RecoveryLocations.copies,includingPropertiesForKeys:nil)) ?? [])
        try external.encoded().write(to:source,options:.atomic)
        doc.presentedItemDidChange()
        try await Task.sleep(for:.milliseconds(30))
        guard doc.state.note == local else { throw Failure(message:"External notification discarded local changes") }
        try await doc.persistLatest()
        let copies = ((try? FileManager.default.contentsOfDirectory(at:RecoveryLocations.copies,includingPropertiesForKeys:nil)) ?? []).filter{ !before.contains($0) }
        guard doc.fileURL == source, try NoteFile.decode(Data(contentsOf:source)) == local,
              copies.isEmpty, doc.state.recoveryMessage == nil else {
            throw Failure(message:"External changes were not silently overwritten in place")
        }
        let corrupt = Data("corrupt external document".utf8)
        let current = doc.fileURL!
        try corrupt.write(to:current,options:.atomic)
        try await doc.persistLatest()
        guard doc.fileURL == source, try NoteFile.decode(Data(contentsOf:source)) == local,
              doc.state.recoveryMessage == nil else { throw Failure(message:"Corrupt external write was not overwritten") }
        guard LightNoteDocumentController.retargetedPath(source.path,from:source,to:doc.fileURL!) == doc.fileURL!.path,
              LightNoteDocumentController.retargetedPath("/unrelated.lightnote",from:source,to:doc.fileURL!) == "/unrelated.lightnote" else {
            throw Failure(message:"Last opened file did not follow conflict copy")
        }
        print("EXTERNAL_CONFLICT_TESTS_PASSED local-edit/notification/silent-in-place-overwrite/corrupt-bytes-replaced")
    }

    static func runRecoveryProcess() async throws {
        guard CommandLine.arguments.contains("--self-test"),
              let path = ProcessInfo.processInfo.environment["LIGHTNOTE_TEST_DIRECTORY"] else { throw Failure(message:"Recovery subprocess not isolated") }
        let folder=URL(fileURLWithPath:path,isDirectory:true)
        if CommandLine.arguments.contains("--recover-only") {
            let report=try await Task.detached {
                try RecoveryJournal.recoverPending(root:RecoveryLocations.journals,destination:RecoveryLocations.copies)
            }.value
            let data=try JSONSerialization.data(withJSONObject:["recovered":report.recovered.map(\.path),"unreadable":report.unreadable.map(\.path)])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)); exit(0)
        }
        NSDocumentController.shared.autosavingDelay=600
        let source=folder.appendingPathComponent("lesson.lightnote")
        let a=InkStroke(samples:[InkSample(x:10,y:20,time:1)])
        try NoteFile(strokes:[a]).encoded().write(to:source)
        let doc=try NoteDocument(contentsOf:source,ofType:"com.lightnote.note")
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.undoManager?.groupsByEvent=false
        func edit(_ body:()->Void) { doc.undoManager?.beginUndoGrouping(); body(); doc.undoManager?.endUndoGrouping() }
        for i in 0..<20 { edit { doc.append(InkStroke(color:.blue,samples:[InkSample(x:Double(i),y:30,time:Double(i))])) } }
        edit { doc.moveStrokes(ids:[a.id],by:CGSize(width:12,height:13)) }
        edit { doc.eraseStrokes(ids:[doc.state.note.strokes[3].id]) }
        doc.undoInk(nil); doc.redoInk(nil)
        edit { doc.setPaperStyle(.blank) }
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.setColor(.red,atX:0,y:0)
        var image=InkStroke(samples:[InkSample(x:100,y:100,time:1),InkSample(x:200,y:150,time:1)])
        image.tool="image"; image.imagePNG=bitmap.representation(using:.png,properties:[:])!
        let shape=InkStroke.shape(.rectangle,from:CGPoint(x:300,y:300),to:CGPoint(x:400,y:350),constrained:false,color:.green,width:2)!
        var free=InkStroke(samples:[InkSample(x:500,y:500,time:1),InkSample(x:520,y:460,time:2),InkSample(x:560,y:490,time:3)])
        free.tool="freeArrow"
        var line=InkStroke(samples:[InkSample(x:600,y:500,time:1),InkSample(x:610,y:400,time:2),InkSample(x:700,y:550,time:3)])
        line=line.straightened()
        edit { doc.appendStrokes([image,shape,free,line],actionName:"이미지·도형·자유 화살표·직선") }
        if CommandLine.arguments.contains("--kill-after-conflict") {
            let external=NoteFile(strokes:[InkStroke(color:.red,samples:[InkSample(x:54321,y:1,time:1)])])
            try external.encoded().write(to:source,options:.atomic)
            doc.presentedItemDidChange()
            try await Task.sleep(for:.milliseconds(20))
            try await doc.persistLatest()
        }
        if CommandLine.arguments.contains("--kill-after-save") || CommandLine.arguments.contains("--normal-close") {
            try await doc.persistLatest()
            if !CommandLine.arguments.contains("--normal-close") { edit { doc.append(InkStroke(samples:[InkSample(x:99,y:99,time:99)])) } }
        }
        if CommandLine.arguments.contains("--kill-during-save") || CommandLine.arguments.contains("--kill-after-temp-write") {
            let started=OSAllocatedUnfairLock(initialState:false)
            let hold: @Sendable () -> Void = {
                started.withLock { $0=true }
                _ = DispatchSemaphore(value:0).wait(timeout:.now()+60)
            }
            if CommandLine.arguments.contains("--kill-after-temp-write") { doc.observeWrittenFileForTesting(hold) }
            else { doc.observeSavesForTesting { _,_ in hold() } }
            _ = Task { try await doc.persistLatest() }
            for _ in 0..<1000 {
                if started.withLock({$0}) { break }
                try await Task.sleep(for:.milliseconds(5))
            }
            guard started.withLock({$0}) else { throw Failure(message:"No save to kill") }
        }
        try RecoveryJournal.durableWrite(doc.state.note.encoded(),to:folder.appendingPathComponent("expected.json"))
        if CommandLine.arguments.contains("--normal-close") {
            doc.close(); print("NORMAL_CLOSE"); exit(0)
        }
        FileHandle.standardOutput.write(Data("READY_TO_KILL\n".utf8))
        try await Task.sleep(for:.seconds(120))
        throw Failure(message:"Subprocess was not killed")
    }
}


extension AppSelfTest {
    static func testDrawingFocus(returnTo original: NSRunningApplication?) async throws {
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<500 {
                if predicate() { return }
                try await Task.sleep(for:.milliseconds(10))
            }
            throw Failure(message:"Focus transition timed out")
        }
        let oldDelay = NSDocumentController.shared.autosavingDelay
        NSDocumentController.shared.autosavingDelay = 60
        defer { NSDocumentController.shared.autosavingDelay = oldDelay }
        let doc = NoteDocument()
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        let window=doc.windowControllers[0].window!
        let canvas=InkCanvasView(state:doc.state)
        window.contentView=canvas
        doc.undoManager?.groupsByEvent=false
        let other=NSWindow(contentRect:NSRect(x:100,y:100,width:300,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        other.isReleasedWhenClosed=false
        let field=NSTextField(frame:NSRect(x:20,y:20,width:200,height:30))
        other.contentView!.addSubview(field)
        defer {
            doc.updateChangeCount(.changeCleared); doc.close(); other.close()
            if let original, original.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                NSApp.yieldActivation(to: original)
                original.activate(options: [])
            }
        }
        func event(_ type: NSEvent.EventType,_ point:CGPoint,_ time:Double) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:time,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:0)!
        }
        window.makeKeyAndOrderFront(nil)
        other.makeKeyAndOrderFront(nil); other.makeFirstResponder(field)
        try await waitFor { other.isKeyWindow }
        guard !window.isKeyWindow else { throw Failure(message:"Focus fixture did not switch windows") }
        doc.undoManager?.beginUndoGrouping()
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:30,y:30),1))
        guard window.isKeyWindow, window.isMainWindow, window.firstResponder === canvas else { throw Failure(message:"Drawing did not focus owning document") }
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:60,y:60),2))
        canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:90,y:50),3))
        doc.undoManager?.endUndoGrouping()
        guard doc.state.note.strokes.count == 1, doc.state.note.strokes[0].samples.first!.point == CGPoint(x:30,y:30) else { throw Failure(message:"First click was lost on window switch") }
        guard let finder=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first else { throw Failure(message:"Finder not running for cross-app activation test") }
        finder.activate(options: [])
        try await waitFor { NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier && !NSApp.isActive }
        doc.undoManager?.beginUndoGrouping()
        canvas.mouseDown(with:event(.leftMouseDown,CGPoint(x:100,y:100),4))
        try await waitFor { NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier && window.isKeyWindow && window.firstResponder === canvas }
        canvas.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:130,y:110),5))
        canvas.mouseUp(with:event(.leftMouseUp,CGPoint(x:160,y:120),6))
        doc.undoManager?.endUndoGrouping()
        guard window.isMainWindow, doc.state.note.strokes.count == 2,
              doc.state.note.strokes.last!.samples.first!.point == CGPoint(x:100,y:100),
              doc.state.note.strokes.last!.samples.last!.point == CGPoint(x:160,y:120) else { throw Failure(message:"First cross-app stroke was interrupted") }
        let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:7,windowNumber:window.windowNumber,context:nil,characters:"e",charactersIgnoringModifiers:"e",isARepeat:false,keyCode:14)!
        NSApp.sendEvent(key)
        guard doc.state.tool == .eraser, window.firstResponder === canvas else { throw Failure(message:"Canvas shortcuts did not follow focus") }
    }
}


extension AppSelfTest {
    static func testToolbarHitAreas(returnTo original: NSRunningApplication?) async throws {
        let state = NoteState()
        let window = NSWindow(contentRect:NSRect(x:150,y:150,width:352,height:58),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.title = "도구 버튼 클릭 검사"
        window.contentView = NSHostingView(rootView:DrawingToolStrip(state:state).frame(width:352,height:58))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            if let original, original.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                NSApp.yieldActivation(to:original); original.activate(options:[])
            }
        }
        try await Task.sleep(for:.milliseconds(100))
        window.contentView!.layoutSubtreeIfNeeded()
        let tools:[InkTool] = [.pen,.eraser,.selection,.laser,.ellipse,.rectangle,.freeArrow,.arrow]
        for (index,tool) in tools.enumerated() {
            // Opposite corners are deliberately outside the symbol's painted pixels.
            for offset in [CGPoint(x:2,y:9),CGPoint(x:42,y:49)] {
                state.selectTool(tool == .pen ? .eraser : .pen)
                let point = CGPoint(x:CGFloat(index)*44+offset.x,y:offset.y)
                let time = ProcessInfo.processInfo.systemUptime
                let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:time,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:time+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
                NSApp.postEvent(up,atStart:true)
                NSApp.sendEvent(down)
                try await Task.sleep(for:.milliseconds(30))
                guard state.tool == tool else { throw Failure(message:"Toolbar padding did not activate \(tool.title), offset=\(offset)") }
            }
        }
        window.setContentSize(NSSize(width:440,height:58))
        window.contentView = NSHostingView(rootView:ColorPresetStrip(state:state).frame(width:440,height:58))
        try await Task.sleep(for:.milliseconds(100))
        window.contentView!.layoutSubtreeIfNeeded()
        for (index,preset) in AppPreferences.shared.colorPresets.enumerated() {
            for offset in [CGPoint(x:2,y:9),CGPoint(x:42,y:49)] {
                state.color = preset.color == .black ? .red : .black
                let point = CGPoint(x:CGFloat(index)*44+offset.x,y:offset.y)
                let time = ProcessInfo.processInfo.systemUptime
                let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:time,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:time+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
                NSApp.postEvent(up,atStart:true)
                NSApp.sendEvent(down)
                try await Task.sleep(for:.milliseconds(30))
                guard state.color == preset.color else { throw Failure(message:"Color padding did not activate \(preset.name), offset=\(offset)") }
            }
        }

        let stickerUIFolder = FileManager.default.temporaryDirectory.appendingPathComponent("LightNote-sticker-ui-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:stickerUIFolder) }
        let stickerUILibrary = StickerLibrary(directory:stickerUIFolder)
        let fixture = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for (index,name) in ["체크", "중요", "칭찬"].enumerated() {
            for x in 0..<32 { for y in 0..<32 {
                let pixel = fixture.bitmapData! + y*fixture.bytesPerRow+x*4
                pixel[0] = index == 0 ? 40 : 240
                pixel[1] = index == 1 ? 180 : 100
                pixel[2] = index == 2 ? 220 : 60
                pixel[3] = 255
            } }
            try stickerUILibrary.add(data:fixture.representation(using:.png,properties:[:])!,name:name)
        }
        window.setContentSize(NSSize(width:640,height:480))
        window.contentView = NSHostingView(rootView:StickerLibraryView(state:state,library:stickerUILibrary))
        try await Task.sleep(for:.milliseconds(150))
        window.contentView!.layoutSubtreeIfNeeded()
        let stickerUIBitmap = window.contentView!.bitmapImageRepForCachingDisplay(in:window.contentView!.bounds)!
        window.contentView!.cacheDisplay(in:window.contentView!.bounds,to:stickerUIBitmap)
        try stickerUIBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/lightnote-stickers-preview.png"))
        let anchor = TooltipAnchorView(text:"볼펜 · P")
        anchor.frame = NSRect(x:100,y:7,width:44,height:44)
        window.contentView = anchor
        window.contentView!.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for:.milliseconds(100))
        window.contentView!.layoutSubtreeIfNeeded()
        anchor.mouseEntered(with:NSEvent.enterExitEvent(with:.mouseEntered,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!)
        guard let tip = anchor.tooltipWindow, tip.isVisible, tip.ignoresMouseEvents,
              tip.frame.minY > window.convertToScreen(anchor.convert(anchor.bounds,to:nil)).maxY,
              window.isKeyWindow else { throw Failure(message:"Tooltip was not above the control or stole focus") }
        anchor.mouseExited(with:NSEvent.enterExitEvent(with:.mouseExited,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!)
        guard anchor.tooltipWindow == nil else { throw Failure(message:"Tooltip did not dismiss") }

    }
}
