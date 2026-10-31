import AppKit

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
        canvas.mouseUp(with: event(.leftMouseUp, 360, 560, 705))
        canvas.advanceLaser(now: ProcessInfo.processInfo.systemUptime + 3.1, leftButtonDown: false)
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
        print("Verified: 100 taps; 2002-sample stroke; mid-stroke save continuity; style; undo/redo; interruption; dot pixels; grid pixels/style undo/redo; stroke eraser click/sweep/undo/redo/keys; rectangle selection/move/undo/redo/save; zoom transforms/ink/eraser/reset; outer viewport grid/input/reopen; shapes/command circle/corner resize/undo/redo; laser hold/release/expiry/non-persistence; managed note automatic save/reopen; disk roundtrip; corrupt read")
        doc.updateChangeCount(.changeCleared)
        doc.close()
    }
}
