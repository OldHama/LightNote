import AppKit
import SwiftUI
import OSLog

struct CanvasHost: NSViewRepresentable {
    let state: NoteState
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = InkScrollView(state: state)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = InkCanvasView(state: state)
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// AppKit preserves the gesture anchor and transforms window coordinates to paper coordinates.
@MainActor
final class InkScrollView: NSScrollView {
    private weak var state: NoteState?
    private var updatingCanvasSize = false
    init(state: NoteState) {
        self.state = state
        super.init(frame: .zero)
        allowsMagnification = true
        minMagnification = 0.25
        maxMagnification = 4
        state.resetZoom = { [weak self] in
            guard let self else { return }
            self.state?.finishInput?()
            let visible = self.contentView.bounds
            self.setMagnification(1, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
            self.state?.zoom = self.magnification
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout()
        ensureCanvasCoverage()
    }
    override var magnification: CGFloat {
        didSet {
            ensureCanvasCoverage()
            state?.zoom = magnification
            state?.refreshCursor?()
        }
    }
    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        // Grow before AppKit constrains the new scroll bounds to the document frame.
        ensureCanvasCoverage(scale: magnification)
        super.setMagnification(magnification, centeredAt: point)
        ensureCanvasCoverage()
        state?.zoom = self.magnification
        state?.refreshCursor?()
    }
    func ensureCanvasCoverage(scale: CGFloat? = nil) {
        guard !updatingCanvasSize, let canvas = documentView as? InkCanvasView else { return }
        updatingCanvasSize = true
        defer { updatingCanvasSize = false }
        let zoom = max(0.01, scale ?? magnification)
        let size = contentView.frame.size
        let visible = contentView.bounds
        canvas.expandWorkspace(to: NSSize(
            width: max(size.width / zoom, visible.maxX),
            height: max(size.height / zoom, visible.maxY)))
    }
    override func magnify(with event: NSEvent) {
        // A transform must not join input samples from different coordinate mappings.
        state?.finishInput?()
        super.magnify(with: event)
        ensureCanvasCoverage()
        documentView?.needsDisplay = true
        state?.zoom = magnification
    }
}

/// Native input and incremental live path. No SwiftUI state changes in the drag loop.
@MainActor
final class InkCanvasView: NSView {
    private struct CachedStroke {
        let path: CGPath
        let bounds: CGRect
        let points: [CGPoint]
    }
    let state: NoteState
    private struct LaserTrace {
        let path: CGPath
        let bounds: CGRect
        var releasedAt: TimeInterval?
        var opacity: Double = 1
    }
    private var activeLaser: InkPathBuilder?
    private var activeLaserBounds = CGRect.null
    private var laserTraces: [LaserTrace] = []
    private var laserTimer: Timer?
    var laserIsFullyVisible: Bool {
        activeLaser != nil && laserTraces.allSatisfy { $0.opacity == 1 && $0.releasedAt == nil }
    }
    var visibleLaserTraceCount: Int { laserTraces.count + (activeLaser == nil ? 0 : 1) }
    private var cache: [UUID: CachedStroke] = [:]
    private struct ShapeDraft {
        let kind: InkShapeKind
        let start: CGPoint
        var end: CGPoint
        var constrained: Bool
        let color: InkColor
        let width: Double
        let id = UUID()
        let time = ProcessInfo.processInfo.systemUptime
        var stroke: InkStroke? {
            InkStroke.shape(kind, from: start, to: end, constrained: constrained,
                            color: color, width: width, id: id, time: time)
        }
    }
    private struct ResizeDrag {
        let source: CGRect
        let anchor: CGPoint
        let corner: CGPoint
        var target: CGPoint
        var transform: CGAffineTransform {
            let sx = abs(target.x-anchor.x)/source.width
            let sy = abs(target.y-anchor.y)/source.height
            return CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                     tx: anchor.x*(1-sx), ty: anchor.y*(1-sy))
        }
    }
    private var shapeDraft: ShapeDraft?
    private var resizeDrag: ResizeDrag?
    static let inkPasteboardType = NSPasteboard.PasteboardType("com.lightnote.ink-selection")
    private var imageCache: [UUID: NSImage] = [:]
    private var lastPasteChangeCount: Int?
    private var pasteRepeatCount = 0
    private var selectedIDs = Set<UUID>()
    private var marqueeStart: CGPoint?
    private var marqueeRect: CGRect?
    private var moveStart: CGPoint?
    private var moveDelta = CGSize.zero
    private var active: InkStroke?
    private var penIsStraight = false
    var displayedStroke: InkStroke? {
        guard let active else { return nil }
        return penIsStraight ? active.straightened() : active
    }
    private func constrainPen(_ enabled: Bool) {
        let next = active?.tool == "pen" && enabled
        guard next != penIsStraight else { return }
        let dirty = active?.bounds ?? .null
        penIsStraight = next
        if !dirty.isNull { setNeedsDisplay(dirty) }
    }
    private var erasingLast: CGPoint?
    private var erasedIDs = Set<UUID>()
    private var liveInk = InkPathBuilder()
    private var lastTimestamp: TimeInterval = 0
    private let log = Logger(subsystem: "com.lightnote.app", category: "Input")
    private var diagnosticEvents = 0
    private var diagnosticTabletEvents = 0
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(state: NoteState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: state.note.pageWidth, height: state.note.pageHeight))
        expandWorkspaceToStoredInk()
        state.copyInk = { [weak self] in self?.copySelection() }
        state.pasteInk = { [weak self] in self?.pasteSelection() }
        state.duplicateInk = { [weak self] in self?.duplicateSelection() }
        state.refreshAppearance = { [weak self] in self?.needsDisplay = true }
        state.refreshCursor = { [weak self] in
            guard let self else { return }
            if self.state.tool != .selection { self.clearSelection() }
            self.refreshToolCursor()
        }
        state.invalidateStrokeCache = { [weak self] ids in
            for id in ids { self?.cache.removeValue(forKey: id) }
            self?.expandWorkspaceToStoredInk()
        }
        state.finishInput = { [weak self] in self?.finishStroke(reason: "document-action") }
        state.invalidate = { [weak self] rect in
            guard let self else { return }
            let ids = Set(self.state.note.strokes.map(\.id))
            self.cache = self.cache.filter { ids.contains($0.key) }
            self.imageCache = self.imageCache.filter { ids.contains($0.key) }
            self.selectedIDs.formIntersection(ids)
            self.state.hasSelection = !self.selectedIDs.isEmpty
            if !self.selectedIDs.isEmpty { self.needsDisplay = true }
            if let rect { self.setNeedsDisplay(rect) } else {
                self.cache.removeAll()
                self.expandWorkspaceToStoredInk()
                (self.enclosingScrollView as? InkScrollView)?.ensureCanvasCoverage()
                self.needsDisplay = true
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned),
            name: NSApplication.willResignActiveNotification, object: nil)
    }
    private func toolCursor() -> NSCursor {
        if [.selection, .laser, .ellipse, .rectangle, .arrow, .freeArrow].contains(state.tool) { return .crosshair }
        guard state.tool == .eraser else { return .arrow }
        // Use the actual canvas-to-window transform, matching event coordinate conversion.
        let diameter = abs(convert(NSSize(width: NoteState.eraserRadius * 2, height: 0), to: nil).width)
        let size = NSSize(width: ceil(diameter + 8), height: ceil(diameter + 8))
        let circleRect = CGRect(x: (size.width - diameter) / 2,
                                y: (size.height - diameter) / 2,
                                width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { _ in
            // Draw both outlines inward: nothing visible extends beyond the hit radius.
            let haloWidth = min(3, diameter * 0.5)
            let halo = NSBezierPath(ovalIn: circleRect.insetBy(dx: haloWidth / 2, dy: haloWidth / 2))
            NSColor.white.setStroke()
            halo.lineWidth = haloWidth
            halo.stroke()
            let outlineWidth = min(1, diameter * 0.25)
            let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))
            NSColor.black.setStroke()
            ring.lineWidth = outlineWidth
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: toolCursor())
    }
    private func refreshToolCursor() {
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow,
           visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            toolCursor().set()
        }
    }

    /// The viewport is always writable; enlarging the workspace never scales stored ink.
    func expandWorkspace(to minimum: NSSize) {
        let size = NSSize(width: max(frame.width, ceil(minimum.width)),
                          height: max(frame.height, ceil(minimum.height)))
        guard size != frame.size else { return }
        setFrameSize(size)
        needsDisplay = true
    }
    private func expandWorkspaceToStoredInk() {
        var extent = CGRect(x: 0, y: 0, width: state.note.pageWidth, height: state.note.pageHeight)
        for stroke in state.note.strokes { extent = extent.union(stroke.bounds) }
        expandWorkspace(to: NSSize(width: extent.maxX + 24, height: extent.maxY + 24))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func appResigned() { finishStroke(reason: "app-inactive") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window { NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window) }
        finishStroke(reason: "window-change")
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                name: NSWindow.didResignKeyNotification, object: newWindow)
        }
    }
    @objc private func windowResigned() { finishStroke(reason: "window-inactive") }
    override func viewDidChangeBackingProperties() {
        finishStroke(reason: "display-change")
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        finishStroke(reason: "new-down")
        window?.makeFirstResponder(self)
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if state.tool == .ellipse || state.tool == .rectangle || state.tool == .arrow {
            let point = convert(event.locationInWindow, from: nil)
            shapeDraft = ShapeDraft(kind: state.tool == .ellipse ? .ellipse : (state.tool == .arrow ? .arrow : .rectangle),
                start: point, end: point, constrained: event.modifierFlags.contains(.command),
                color: state.color, width: state.width)
            return
        }
        if state.tool == .laser {
            let now = ProcessInfo.processInfo.systemUptime
            // Restore only still-visible traces to full brightness on a new hold.
            laserTraces.removeAll { $0.opacity * LaserTiming.opacity(releasedAt: $0.releasedAt, now: now) <= 0 }
            for index in laserTraces.indices {
                laserTraces[index].opacity = 1
                laserTraces[index].releasedAt = nil
                setNeedsDisplay(laserTraces[index].bounds.insetBy(dx: -laserPadding, dy: -laserPadding))
            }
            activeLaser = InkPathBuilder()
            activeLaserBounds = .null
            appendLaser(event)
            startLaserTimer()
            return
        }
        if state.tool == .selection {
            let point = convert(event.locationInWindow, from: nil)
            if let rect = selectionBounds, let corner = handleCorners(rect).first(where: {
                abs($0.x-point.x) <= handleRadius && abs($0.y-point.y) <= handleRadius &&
                hypot($0.x-point.x, $0.y-point.y) < hypot(rect.midX-point.x, rect.midY-point.y)
            }) {
                let anchor = CGPoint(x: corner.x == rect.minX ? rect.maxX : rect.minX,
                                     y: corner.y == rect.minY ? rect.maxY : rect.minY)
                resizeDrag = ResizeDrag(source: rect, anchor: anchor, corner: corner, target: corner)
            } else if let rect = selectionBounds, rect.contains(point) {
                moveStart = point
                moveDelta = .zero
            } else {
                clearSelection()
                marqueeStart = point
                marqueeRect = CGRect(origin: point, size: .zero)
            }
            return
        }
        if state.tool == .eraser {
            erasingLast = convert(event.locationInWindow, from: nil)
            erase(with: event)
            return
        }
        active = InkStroke(color: state.color, width: state.width, samples: [])
        if state.tool == .freeArrow { active?.tool = "freeArrow" }
        liveInk = InkPathBuilder()
        diagnosticEvents = 0; diagnosticTabletEvents = 0
        append(event)
    }
    override func mouseDragged(with event: NSEvent) {
        if shapeDraft != nil { updateShape(with: event); return }
        if activeLaser != nil { appendLaser(event); return }
        if marqueeStart != nil || moveStart != nil || resizeDrag != nil { updateSelection(with: event); return }
        if erasingLast != nil { erase(with: event); return }
        guard active != nil else { return } // Never bridge a disconnected input session.
        append(event)
    }
    override func mouseUp(with event: NSEvent) {
        if shapeDraft != nil {
            updateShape(with: event)
            finishStroke(reason: "shape-up")
            return
        }
        if activeLaser != nil {
            appendLaser(event)
            finishLaser()
            return
        }
        if marqueeStart != nil || moveStart != nil || resizeDrag != nil {
            updateSelection(with: event)
            finishStroke(reason: "selection-up")
            return
        }
        if erasingLast != nil {
            erase(with: event)
            finishStroke(reason: "eraser-up")
            return
        }
        guard active != nil else { return }
        append(event)
        finishStroke(reason: "up")
    }
    override func tabletPoint(with event: NSEvent) {
        // AppKit may deliver independent tablet-point events between mouse events.
        if shapeDraft != nil { updateShape(with: event); return }
        if activeLaser != nil { appendLaser(event); return }
        if marqueeStart != nil || moveStart != nil || resizeDrag != nil { updateSelection(with: event); return }
        if erasingLast != nil { erase(with: event); return }
        guard active != nil else { return }
        append(event)
    }
    override func tabletProximity(with event: NSEvent) {
        if !event.isEnteringProximity { finishStroke(reason: "proximity-exit") }
    }

    @discardableResult
    func copySelection(to pasteboard: NSPasteboard? = nil) -> Bool {
        finishStroke(reason: "copy")
        let strokes = state.note.strokes.filter { selectedIDs.contains($0.id) }
        guard !strokes.isEmpty, let data = try? NoteFile(strokes: strokes).encoded() else { return false }
        let board = pasteboard ?? .general
        board.clearContents()
        board.setData(data, forType: Self.inkPasteboardType)
        lastPasteChangeCount = nil; pasteRepeatCount = 0
        return true
    }
    @discardableResult
    func pasteSelection(from pasteboard: NSPasteboard? = nil) -> Bool {
        let board = pasteboard ?? .general
        if board.data(forType: Self.inkPasteboardType) == nil {
            guard let image = NSImage(pasteboard: board),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]),
                  png.count <= 50_000_000, image.size.width > 0, image.size.height > 0 else { return false }
            let viewport = visibleRect.isEmpty ? bounds : visibleRect
            let scale = min(1, viewport.width * 0.7 / image.size.width, viewport.height * 0.7 / image.size.height)
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            var object = InkStroke(samples: [InkSample(x: viewport.midX-size.width/2, y: viewport.midY-size.height/2, time: 0),
                                              InkSample(x: viewport.midX+size.width/2, y: viewport.midY+size.height/2, time: 0)])
            object.tool = "image"; object.imagePNG = png
            return insertCopies([object], offsetIndex: 0, actionName: "이미지 붙여넣기")
        }
        guard let data = board.data(forType: Self.inkPasteboardType),
              let file = try? NoteFile.decode(data), !file.strokes.isEmpty else { return false }
        if lastPasteChangeCount == board.changeCount { pasteRepeatCount += 1 }
        else { lastPasteChangeCount = board.changeCount; pasteRepeatCount = 1 }
        return insertCopies(file.strokes, offsetIndex: pasteRepeatCount, actionName: "붙여넣기")
    }
    @discardableResult
    func duplicateSelection() -> Bool {
        finishStroke(reason: "duplicate")
        return insertCopies(state.note.strokes.filter { selectedIDs.contains($0.id) },
                            offsetIndex: 1, actionName: "복제")
    }
    private func insertCopies(_ originals: [InkStroke], offsetIndex: Int, actionName: String) -> Bool {
        guard !originals.isEmpty, let document = state.document else { return false }
        finishStroke(reason: "paste")
        let box = originals.reduce(CGRect.null) { $0.union($1.bounds) }
        let offset = CGFloat(offsetIndex) * 20 / (enclosingScrollView?.magnification ?? 1)
        let viewport = visibleRect.isEmpty ? bounds : visibleRect
        var delta = CGSize(width: offset, height: offset)
        if !viewport.contains(CGPoint(x: box.minX+offset, y: box.minY+offset)) {
            delta = CGSize(width: viewport.minX+offset-box.minX, height: viewport.minY+offset-box.minY)
        }
        let copies = originals.map { $0.copied(offset: delta) }
        guard (try? NoteFile(strokes: copies).validate()) != nil else { return false }
        clearSelection()
        state.selectTool(.selection)
        let area = copies.reduce(CGRect.null) { $0.union($1.bounds) }
        expandWorkspace(to: NSSize(width: area.maxX+24, height: area.maxY+24))
        document.appendStrokes(copies, actionName: actionName)
        selectedIDs = Set(copies.map(\.id))
        state.hasSelection = true
        setNeedsDisplay(area.insetBy(dx: -handleRadius*2, dy: -handleRadius*2))
        window?.makeFirstResponder(self)
        return true
    }

    private var handleRadius: CGFloat { 7 / (enclosingScrollView?.magnification ?? 1) }
    private func handleCorners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    private var selectionTransform: CGAffineTransform {
        resizeDrag?.transform ?? CGAffineTransform(translationX: moveDelta.width, y: moveDelta.height)
    }
    private func updateShape(with event: NSEvent) {
        guard shapeDraft != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        let old = shapeDraft?.stroke?.bounds ?? .null
        shapeDraft?.end = point
        shapeDraft?.constrained = event.modifierFlags.contains(.command)
        let rect = shapeDraft?.stroke?.bounds ?? .null
        if !rect.isNull {
            expandWorkspace(to: NSSize(width: rect.maxX+24, height: rect.maxY+24))
            setNeedsDisplay(old.union(rect))
        } else if !old.isNull { setNeedsDisplay(old) }
    }
    override func flagsChanged(with event: NSEvent) {
        constrainPen(event.modifierFlags.contains(.shift))
        if shapeDraft != nil {
            let old = shapeDraft?.stroke?.bounds ?? .null
            shapeDraft?.constrained = event.modifierFlags.contains(.command)
            let rect = shapeDraft?.stroke?.bounds ?? .null
            if !old.union(rect).isNull { setNeedsDisplay(old.union(rect)) }
        }
        super.flagsChanged(with: event)
    }

    private var laserPadding: CGFloat { 12 / (enclosingScrollView?.magnification ?? 1) }
    private func appendLaser(_ event: NSEvent) {
        guard let activeLaser else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        let previous = activeLaser.path.currentPoint
        let last = activeLaser.lastPoint ?? point
        activeLaser.append(point)
        let segment = CGRect(x: min(previous.x, last.x, point.x), y: min(previous.y, last.y, point.y),
                             width: max(previous.x, last.x, point.x)-min(previous.x, last.x, point.x),
                             height: max(previous.y, last.y, point.y)-min(previous.y, last.y, point.y))
        activeLaserBounds = activeLaserBounds.union(CGRect(origin: point, size: .zero))
        setNeedsDisplay(segment.insetBy(dx: -laserPadding, dy: -laserPadding))
    }
    private func finishLaser(releasedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let activeLaser else { return }
        activeLaser.finish()
        for index in laserTraces.indices where laserTraces[index].releasedAt == nil {
            laserTraces[index].releasedAt = releasedAt
        }
        laserTraces.append(LaserTrace(path: activeLaser.path.copy()!, bounds: activeLaserBounds,
                                      releasedAt: releasedAt))
        self.activeLaser = nil
        setNeedsDisplay(activeLaserBounds.insetBy(dx: -laserPadding, dy: -laserPadding))
        startLaserTimer()
    }
    private func startLaserTimer() {
        if laserTimer == nil {
            let timer = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated {
                    self.advanceLaser(now: ProcessInfo.processInfo.systemUptime)
                }
            }
            laserTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func advanceLaser(now: TimeInterval, leftButtonDown: Bool? = nil) {
        // Recover a release outside the window without treating saves/zoom as mouseUp.
        if activeLaser != nil, !(leftButtonDown ?? (NSEvent.pressedMouseButtons & 1 != 0)) {
            finishLaser(releasedAt: now)
        }
        for trace in laserTraces {
            setNeedsDisplay(trace.bounds.insetBy(dx: -laserPadding, dy: -laserPadding))
        }
        laserTraces.removeAll { $0.opacity * LaserTiming.opacity(releasedAt: $0.releasedAt, now: now) <= 0 }
        if laserTraces.isEmpty && activeLaser == nil { laserTimer?.invalidate(); laserTimer = nil }
    }
    private func drawLaser(_ path: CGPath, tail: CGPoint?, opacity: Double, context: CGContext) {
        guard opacity > 0 else { return }
        let scale = enclosingScrollView?.magnification ?? 1
        context.saveGState()
        context.setAlpha(opacity)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0.06, blue: 0.13, alpha: 1))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.06, blue: 0.13, alpha: 1))
        context.setLineWidth(2.5 / scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShadow(offset: .zero, blur: 6 / scale,
                          color: CGColor(srgbRed: 1, green: 0, blue: 0.1, alpha: 0.8))
        if path.boundingBoxOfPath.size == .zero && (tail == nil || tail == path.currentPoint) {
            let point = path.currentPoint, radius = 2 / scale
            context.fillEllipse(in: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2))
        } else {
            context.addPath(path)
            if let tail { context.addLine(to: tail) }
            context.strokePath()
        }
        context.restoreGState()
    }

    private var selectionBounds: CGRect? {
        let rect = state.note.strokes.filter { selectedIDs.contains($0.id) }
            .reduce(CGRect.null) { $0.union($1.bounds) }
        guard !rect.isNull else { return nil }
        let margin = 5 / (enclosingScrollView?.magnification ?? 1)
        return rect.insetBy(dx: -margin, dy: -margin)
    }
    private func clearSelection() {
        if let rect = selectionBounds {
            setNeedsDisplay(rect.union(rect.applying(selectionTransform))
                .insetBy(dx: -handleRadius*2, dy: -handleRadius*2))
        }
        if let rect = marqueeRect { setNeedsDisplay(rect.insetBy(dx: -3, dy: -3)) }
        selectedIDs.removeAll()
        state.hasSelection = false
        marqueeStart = nil; marqueeRect = nil; moveStart = nil; moveDelta = .zero; resizeDrag = nil
    }
    private func updateSelection(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        let padding = handleRadius * 2
        if var resize = resizeDrag {
            let old = resize.source.applying(resize.transform)
            let minimum = 12 / (enclosingScrollView?.magnification ?? 1)
            resize.target = CGPoint(
                x: resize.corner.x < resize.anchor.x ? min(point.x, resize.anchor.x-minimum) : max(point.x, resize.anchor.x+minimum),
                y: resize.corner.y < resize.anchor.y ? min(point.y, resize.anchor.y-minimum) : max(point.y, resize.anchor.y+minimum))
            resizeDrag = resize
            let updated = resize.source.applying(resize.transform)
            expandWorkspace(to: NSSize(width: updated.maxX+24, height: updated.maxY+24))
            setNeedsDisplay(old.union(updated).insetBy(dx: -padding, dy: -padding))
        } else if let start = marqueeStart {
            let old = marqueeRect ?? .null
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x-start.x), height: abs(point.y-start.y))
            marqueeRect = rect
            setNeedsDisplay(old.union(rect).insetBy(dx: -padding, dy: -padding))
        } else if let start = moveStart, let rect = selectionBounds {
            let old = rect.offsetBy(dx: moveDelta.width, dy: moveDelta.height)
            // Keep strokes reachable at the top and left workspace edges.
            let ink = state.note.strokes.filter { selectedIDs.contains($0.id) }
                .reduce(CGRect.null) { $0.union($1.bounds) }
            moveDelta = CGSize(width: max(-ink.minX, point.x-start.x),
                               height: max(-ink.minY, point.y-start.y))
            let updated = rect.offsetBy(dx: moveDelta.width, dy: moveDelta.height)
            expandWorkspace(to: NSSize(width: updated.maxX + 24, height: updated.maxY + 24))
            setNeedsDisplay(old.union(updated).insetBy(dx: -padding, dy: -padding))
        }
    }
    private func finishSelection() {
        if let resize = resizeDrag {
            resizeDrag = nil
            if resize.target != resize.corner {
                state.document?.transformStrokes(ids: selectedIDs, using: resize.transform)
            }
        }
        if let rect = marqueeRect, marqueeStart != nil {
            selectedIDs = Set(state.note.strokes.filter { stroke in
                guard stroke.bounds.intersects(rect) else { return false }
                if stroke.tool == "image" { return true }
                let points = cache[stroke.id]?.points ?? InkPathBuilder.make(stroke: stroke).points
                if points.contains(where: { rect.contains($0) }) { return true }
                let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                return (0..<4).contains { index in
                    stroke.intersectsEraser(from: corners[index], to: corners[(index+1)%4], radius: 0, polyline: points)
                }
            }.map(\.id))
            state.hasSelection = !selectedIDs.isEmpty
            marqueeStart = nil; marqueeRect = nil
            setNeedsDisplay(rect.insetBy(dx: -10, dy: -10))
            if let selectionBounds { setNeedsDisplay(selectionBounds.insetBy(dx: -3, dy: -3)) }
        }
        if moveStart != nil {
            let delta = moveDelta
            moveStart = nil; moveDelta = .zero
            state.document?.moveStrokes(ids: selectedIDs, by: delta)
        }
    }

    private func append(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let tablet = event.type == .tabletPoint || event.subtype == .tabletPoint
        let pressure = tablet ? Double(min(1, max(0, event.pressure))) : nil
        let sample = InkSample(x: point.x, y: point.y, time: event.timestamp, pressure: pressure)
        guard point.x.isFinite, point.y.isFinite else { return }
        // Out-of-order samples cannot create a backward segment. Same timestamps remain valid.
        if active?.samples.isEmpty == false, event.timestamp < lastTimestamp { return }
        lastTimestamp = event.timestamp
        diagnosticEvents += 1
        if tablet { diagnosticTabletEvents += 1 }
        let oldLine = penIsStraight ? (displayedStroke?.bounds ?? .null) : .null
        constrainPen(event.modifierFlags.contains(.shift))
        let previousHead = active?.freeArrowHeadBounds ?? .null
        let previous = active?.samples.last?.point
        active?.samples.append(sample)
        if point.x >= bounds.maxX || point.y >= bounds.maxY {
            expandWorkspace(to: NSSize(width: point.x + 128, height: point.y + 128))
        }
        let changedStart = liveInk.path.currentPoint
        liveInk.append(point)
        let radius = (active?.width ?? 1) / 2 + 2
        let start = previous ?? point
        let dirty = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y))
            .insetBy(dx: -radius, dy: -radius)
        let curveDirty = CGRect(x: min(changedStart.x, start.x, point.x),
                                y: min(changedStart.y, start.y, point.y),
                                width: max(changedStart.x, start.x, point.x) - min(changedStart.x, start.x, point.x),
                                height: max(changedStart.y, start.y, point.y) - min(changedStart.y, start.y, point.y))
            .insetBy(dx: -radius, dy: -radius)
        let headDirty = previousHead.union(active?.freeArrowHeadBounds ?? .null).insetBy(dx: -radius, dy: -radius)
        let newLine = penIsStraight ? (displayedStroke?.bounds ?? .null) : .null
        setNeedsDisplay(dirty.union(curveDirty).union(headDirty).union(oldLine).union(newLine))
    }
    private func erase(with event: NSEvent) {
        guard let previous = erasingLast else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        let sweep = CGRect(x: min(previous.x, point.x), y: min(previous.y, point.y),
                           width: abs(point.x - previous.x), height: abs(point.y - previous.y))
            .insetBy(dx: -NoteState.eraserRadius, dy: -NoteState.eraserRadius)
        for stroke in state.note.strokes where !erasedIDs.contains(stroke.id) {
            if let cached = cache[stroke.id], !cached.bounds.intersects(sweep) { continue }
            if stroke.intersectsEraser(from: previous, to: point, radius: NoteState.eraserRadius, polyline: cache[stroke.id]?.points) {
                erasedIDs.insert(stroke.id)
                setNeedsDisplay(stroke.bounds)
            }
        }
        erasingLast = point
    }
    func finishStroke(reason: String) {
        // Only an actual mouse release (or replacement down event) starts laser fading.
        if reason == "new-down" { finishLaser() }
        if let draft = shapeDraft {
            shapeDraft = nil
            if let stroke = draft.stroke { state.document?.append(stroke) }
        }
        finishSelection()
        if erasingLast != nil {
            erasingLast = nil
            let ids = erasedIDs
            erasedIDs.removeAll()
            state.document?.eraseStrokes(ids: ids)
        }
        guard let stroke = displayedStroke, !stroke.samples.isEmpty else { penIsStraight = false; return }
        let wasStraight = penIsStraight
        active = nil
        penIsStraight = false
        liveInk.finish()
        if wasStraight || stroke.tool == "freeArrow" {
            let geometry = InkPathBuilder.make(stroke: stroke)
            cache[stroke.id] = CachedStroke(path: geometry.path.copy()!, bounds: stroke.bounds, points: geometry.points)
        } else {
            cache[stroke.id] = CachedStroke(path: liveInk.path.copy()!, bounds: stroke.bounds, points: liveInk.points)
        }
        state.document?.append(stroke)
        log.debug("Stroke samples=\(stroke.samples.count) events=\(self.diagnosticEvents) tablet=\(self.diagnosticTabletEvents) finish=\(reason, privacy: .public)")
        liveInk = InkPathBuilder()
    }
    override func keyDown(with event: NSEvent) {
        // Handle only canvas input, so text editors retain normal bracket typing.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 44 || event.charactersIgnoringModifiers == "/" {
                state.showShortcuts = true
                return
            }
            if state.tool == .selection, event.keyCode == 51 || event.keyCode == 117 {
                guard !selectedIDs.isEmpty else { return }
                finishStroke(reason: "selection-delete")
                let ids = selectedIDs
                clearSelection()
                state.document?.eraseStrokes(ids: ids)
                state.document?.undoManager?.setActionName("선택 삭제")
                return
            }
            if let preset = NoteState.colorPresets.first(where: { $0.key == event.charactersIgnoringModifiers }) {
                state.color = preset.color
                return
            }
            // Physical bracket keys also work while the Korean input source is active.
            if event.keyCode == 33 || event.charactersIgnoringModifiers == "[" {
                state.adjustPenWidth(increase: false)
                return
            }
            if event.keyCode == 30 || event.charactersIgnoringModifiers == "]" {
                state.adjustPenWidth(increase: true)
                return
            }
            if event.keyCode == 12 || event.charactersIgnoringModifiers?.lowercased() == "q" {
                state.selectTool(.freeArrow)
                return
            }
            if event.keyCode == 0 || event.charactersIgnoringModifiers?.lowercased() == "a" {
                state.selectTool(.arrow)
                return
            }
            if event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c" {
                state.selectTool(.ellipse)
                return
            }
            if event.keyCode == 15 || event.charactersIgnoringModifiers?.lowercased() == "r" {
                state.selectTool(.rectangle)
                return
            }
            if event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l" {
                state.selectTool(.laser)
                return
            }
            if event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v" {
                state.selectTool(.selection)
                return
            }
            if event.keyCode == 53 {
                if let rect = shapeDraft?.stroke?.bounds { setNeedsDisplay(rect) }
                shapeDraft = nil
                clearSelection()
                return
            }
            if event.keyCode == 14 || event.charactersIgnoringModifiers?.lowercased() == "e" {
                state.selectTool(.eraser)
                return
            }
            if event.keyCode == 35 || event.charactersIgnoringModifiers?.lowercased() == "p" {
                state.selectTool(.pen)
                return
            }
        }
        super.keyDown(with: event)
    }
    @objc func undo(_ sender: Any?) { state.document?.undoInk(sender) }
    @objc func redo(_ sender: Any?) { state.document?.redoInk(sender) }
    override var undoManager: UndoManager? { state.document?.undoManager }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let paperColor = state.note.paperStyle == .grid
            ? AppPreferences.shared.paperColor.cgColor
            : NSColor.white.cgColor
        context.setFillColor(paperColor)
        context.fill(dirtyRect)
        if state.note.paperStyle == .grid {
            drawGrid(in: dirtyRect, context: context)
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        for stroke in state.note.strokes where !erasedIDs.contains(stroke.id) {
            if stroke.tool == "image" {
                let image: NSImage?
                if let cached = imageCache[stroke.id] { image = cached }
                else { image = stroke.imagePNG.flatMap(NSImage.init(data:)); imageCache[stroke.id] = image }
                if let image, stroke.samples.count == 2 {
                    let a = stroke.samples[0].point, b = stroke.samples[1].point
                    let rect = CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
                    context.saveGState()
                    if selectedIDs.contains(stroke.id) { context.concatenate(selectionTransform) }
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    context.restoreGState()
                }
                continue
            }
            let cached: CachedStroke
            if let existing = cache[stroke.id] { cached = existing }
            else {
                let geometry = InkPathBuilder.make(stroke: stroke)
                cached = CachedStroke(path: geometry.path.copy()!, bounds: stroke.bounds, points: geometry.points)
                cache[stroke.id] = cached
            }
            var transform = selectedIDs.contains(stroke.id) ? selectionTransform : .identity
            if cached.bounds.applying(transform).intersects(dirtyRect) {
                let path = transform.isIdentity ? cached.path : (cached.path.copy(using: &transform) ?? cached.path)
                render(stroke, path: path, in: context)
            }
        }
        if let shape = shapeDraft?.stroke {
            let geometry = InkPathBuilder.make(stroke: shape)
            render(shape, path: geometry.path, in: context)
        }
        if let active = displayedStroke {
            if penIsStraight {
                let line = CGMutablePath()
                line.addLines(between: active.samples.map(\.point))
                render(active, path: line, in: context)
            } else { render(active, path: liveInk.path, tail: liveInk.lastPoint, in: context) }
            let head = active.freeArrowHead
            if !head.isEmpty {
                context.beginPath(); context.addLines(between: head)
                context.strokePath()
            }
        }
        if state.tool == .selection,
           let rect = marqueeRect ?? selectionBounds?.applying(selectionTransform) {
            let scale = enclosingScrollView?.magnification ?? 1
            context.saveGState()
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 3 / scale])
            context.stroke(rect)
            if marqueeRect == nil {
                context.setLineDash(phase: 0, lengths: [])
                context.setFillColor(NSColor.white.cgColor)
                for corner in handleCorners(rect) {
                    let box = CGRect(x: corner.x-4/scale, y: corner.y-4/scale, width: 8/scale, height: 8/scale)
                    context.fill(box)
                    context.stroke(box)
                }
            }
            context.restoreGState()
        }
        let now = ProcessInfo.processInfo.systemUptime
        for trace in laserTraces {
            drawLaser(trace.path, tail: nil, opacity: trace.opacity * LaserTiming.opacity(releasedAt: trace.releasedAt, now: now), context: context)
        }
        if let activeLaser { drawLaser(activeLaser.path, tail: activeLaser.lastPoint, opacity: 1, context: context) }
    }
    /// Grid coordinates are anchored to the paper, so scrolling and partial redraws agree.
    private func drawGrid(in dirtyRect: CGRect, context: CGContext) {
        let spacing = CGFloat(AppPreferences.shared.gridSpacing)
        let visible = dirtyRect.intersection(bounds)
        guard !visible.isEmpty else { return }
        context.saveGState()
        context.clip(to: visible)
        context.setStrokeColor(AppPreferences.shared.gridColor.cgColor)
        context.setLineWidth(0.5)
        let path = CGMutablePath()
        for x in stride(from: ceil(visible.minX / spacing) * spacing, through: visible.maxX, by: spacing) {
            path.move(to: CGPoint(x: x, y: visible.minY))
            path.addLine(to: CGPoint(x: x, y: visible.maxY))
        }
        for y in stride(from: ceil(visible.minY / spacing) * spacing, through: visible.maxY, by: spacing) {
            path.move(to: CGPoint(x: visible.minX, y: y))
            path.addLine(to: CGPoint(x: visible.maxX, y: y))
        }
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private func render(_ stroke: InkStroke, path: CGPath, tail: CGPoint? = nil, in context: CGContext) {
        context.setStrokeColor(stroke.color.cgColor)
        context.setFillColor(stroke.color.cgColor)
        context.setLineWidth(stroke.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if let first = stroke.samples.first,
           stroke.samples.allSatisfy({ $0.x == first.x && $0.y == first.y }) {
            // CGPath with no length has no visible stroke; clicks must still leave a dot.
            context.fillEllipse(in: CGRect(x: first.x - stroke.width / 2, y: first.y - stroke.width / 2,
                                          width: stroke.width, height: stroke.width))
        } else {
            context.addPath(path)
            if let tail { context.addLine(to: tail) }
            context.strokePath()
        }
    }
}
