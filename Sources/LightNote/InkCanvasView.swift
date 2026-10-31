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
    private var cache: [UUID: CachedStroke] = [:]
    private var selectedIDs = Set<UUID>()
    private var marqueeStart: CGPoint?
    private var marqueeRect: CGRect?
    private var moveStart: CGPoint?
    private var moveDelta = CGSize.zero
    private var active: InkStroke?
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
            self.selectedIDs.formIntersection(ids)
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
        if state.tool == .selection { return .crosshair }
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
        if state.tool == .selection {
            let point = convert(event.locationInWindow, from: nil)
            if let rect = selectionBounds, rect.contains(point) {
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
        liveInk = InkPathBuilder()
        diagnosticEvents = 0; diagnosticTabletEvents = 0
        append(event)
    }
    override func mouseDragged(with event: NSEvent) {
        if marqueeStart != nil || moveStart != nil { updateSelection(with: event); return }
        if erasingLast != nil { erase(with: event); return }
        guard active != nil else { return } // Never bridge a disconnected input session.
        append(event)
    }
    override func mouseUp(with event: NSEvent) {
        if marqueeStart != nil || moveStart != nil {
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
        if marqueeStart != nil || moveStart != nil { updateSelection(with: event); return }
        if erasingLast != nil { erase(with: event); return }
        guard active != nil else { return }
        append(event)
    }
    override func tabletProximity(with event: NSEvent) {
        if !event.isEnteringProximity { finishStroke(reason: "proximity-exit") }
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
            setNeedsDisplay(rect.union(rect.offsetBy(dx: moveDelta.width, dy: moveDelta.height))
                .insetBy(dx: -3, dy: -3))
        }
        if let rect = marqueeRect { setNeedsDisplay(rect.insetBy(dx: -3, dy: -3)) }
        selectedIDs.removeAll()
        marqueeStart = nil; marqueeRect = nil; moveStart = nil; moveDelta = .zero
    }
    private func updateSelection(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite else { return }
        let padding = 4 / (enclosingScrollView?.magnification ?? 1)
        if let start = marqueeStart {
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
        if let rect = marqueeRect, marqueeStart != nil {
            selectedIDs = Set(state.note.strokes.filter { stroke in
                guard stroke.bounds.intersects(rect) else { return false }
                let points = cache[stroke.id]?.points ?? InkPathBuilder.make(samples: stroke.samples).points
                if points.contains(where: { rect.contains($0) }) { return true }
                let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                return (0..<4).contains { index in
                    stroke.intersectsEraser(from: corners[index], to: corners[(index+1)%4], radius: 0, polyline: points)
                }
            }.map(\.id))
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
        setNeedsDisplay(dirty.union(curveDirty))
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
        finishSelection()
        if erasingLast != nil {
            erasingLast = nil
            let ids = erasedIDs
            erasedIDs.removeAll()
            state.document?.eraseStrokes(ids: ids)
        }
        guard let stroke = active, !stroke.samples.isEmpty else { return }
        active = nil
        liveInk.finish()
        cache[stroke.id] = CachedStroke(path: liveInk.path.copy()!, bounds: stroke.bounds, points: liveInk.points)
        state.document?.append(stroke)
        log.debug("Stroke samples=\(stroke.samples.count) events=\(self.diagnosticEvents) tablet=\(self.diagnosticTabletEvents) finish=\(reason, privacy: .public)")
        liveInk = InkPathBuilder()
    }
    override func keyDown(with event: NSEvent) {
        // Handle only canvas input, so text editors retain normal bracket typing.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
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
            if event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v" {
                state.selectTool(.selection)
                return
            }
            if event.keyCode == 53 { clearSelection(); return }
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
            ? CGColor(srgbRed: 1, green: 0.985, blue: 0.94, alpha: 1)
            : NSColor.white.cgColor
        context.setFillColor(paperColor)
        context.fill(dirtyRect)
        if state.note.paperStyle == .grid {
            drawGrid(in: dirtyRect, context: context)
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        for stroke in state.note.strokes where !erasedIDs.contains(stroke.id) {
            let cached: CachedStroke
            if let existing = cache[stroke.id] { cached = existing }
            else {
                let geometry = InkPathBuilder.make(samples: stroke.samples)
                cached = CachedStroke(path: geometry.path.copy()!, bounds: stroke.bounds, points: geometry.points)
                cache[stroke.id] = cached
            }
            let selected = selectedIDs.contains(stroke.id)
            let delta = selected ? moveDelta : .zero
            if cached.bounds.offsetBy(dx: delta.width, dy: delta.height).intersects(dirtyRect) {
                context.saveGState()
                context.translateBy(x: delta.width, y: delta.height)
                render(stroke, path: cached.path, in: context)
                context.restoreGState()
            }
        }
        if let active { render(active, path: liveInk.path, tail: liveInk.lastPoint, in: context) }
        if state.tool == .selection,
           let rect = marqueeRect ?? selectionBounds?.offsetBy(dx: moveDelta.width, dy: moveDelta.height) {
            let scale = enclosingScrollView?.magnification ?? 1
            context.saveGState()
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 3 / scale])
            context.stroke(rect)
            context.restoreGState()
        }
    }
    /// Grid coordinates are anchored to the paper, so scrolling and partial redraws agree.
    private func drawGrid(in dirtyRect: CGRect, context: CGContext) {
        let spacing: CGFloat = 20
        let visible = dirtyRect.intersection(bounds)
        guard !visible.isEmpty else { return }
        context.saveGState()
        context.clip(to: visible)
        context.setStrokeColor(CGColor(srgbRed: 0.78, green: 0.84, blue: 0.91, alpha: 1))
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
