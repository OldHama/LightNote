import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var state: NoteState
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var updateAvailability = UpdateAvailability.shared
    var body: some View {
        VStack(spacing: 0) {
            if let message = state.recoveryMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message).lineLimit(2)
                    Spacer()
                    Button("폴더 열기") { NSWorkspace.shared.open(RecoveryLocations.parent) }
                    Button { state.recoveryMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.caption).padding(8).background(Color.yellow.opacity(0.15))
            }
            HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Button { NoteLibraryWindowController.shared.present() } label: { Label("보관함",systemImage:"square.grid.2x2") }
                        .topTooltip("노트 보관함").accessibilityLabel("노트 보관함").buttonStyle(ToolbarActionButtonStyle())
                    Button { state.finishInput?(); state.document?.save(nil) } label: { FloppyDiskIcon() }
                        .topTooltip("저장 · ⌘S").accessibilityLabel("저장").buttonStyle(ToolbarActionButtonStyle())
                    Button { state.showShortcuts = true } label: {
                        Image(systemName: "questionmark.circle")
                    }.topTooltip("단축키 도움말 · /").accessibilityLabel("단축키 도움말").buttonStyle(ToolbarActionButtonStyle())
                    Divider().frame(height: 22)
                    Button { state.document?.undoInk(nil) } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!state.canUndo).topTooltip("실행 취소 · ⌘Z").accessibilityLabel("실행 취소").buttonStyle(ToolbarActionButtonStyle())
                    Button { state.document?.redoInk(nil) } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!state.canRedo).topTooltip("다시 실행 · ⌘⇧Z").accessibilityLabel("다시 실행").buttonStyle(ToolbarActionButtonStyle())
                    Divider().frame(height: 22)
                    DrawingToolStrip(state: state)
                    Button { state.showStickers = true } label: {
                        Label("스티커",systemImage:"face.smiling").padding(.horizontal,12).frame(height:44).contentShape(Rectangle())
                    }
                        .buttonStyle(DrawingToolButtonStyle(tint:.accentColor,springPress:true))
                        .topTooltip("등록한 스티커 사용").accessibilityLabel("스티커함")
                    ColorPresetStrip(state: state)
                    ColorPicker("색상", selection: Binding(get: { Color(cgColor: state.color.cgColor) }, set: {
                        guard let c = NSColor($0).usingColorSpace(.sRGB) else { return }
                        state.color = InkColor(c.redComponent, c.greenComponent, c.blueComponent)
                    }), supportsOpacity: false).labelsHidden().topTooltip("사용자 지정 색상")
                    Picker("두께", selection: $state.width) {
                        ForEach(NoteState.penWidths, id: \.self) { width in
                            Text(String(format: "%.1f pt", width)).tag(width)
                        }
                    }.frame(width: 110).labelsHidden().topTooltip("펜 두께 · [ 얇게 / ] 두껍게")
                    Divider().frame(height: 22)
                    Picker("용지", selection: Binding(
                        get: { state.note.paperStyle },
                        set: { state.document?.setPaperStyle($0) }
                    )) {
                        Text("무지").tag(PaperStyle.blank)
                        Text("모눈").tag(PaperStyle.grid)
                    }.frame(width: 120).topTooltip("용지 유형 · 무지 / 모눈")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 18).frame(height: 58)
            }
            .frame(height: 58)
            if let version = updateAvailability.version {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: NSApp.delegate, from: nil)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22)).foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
                .topTooltip("LightNote " + version + " 다운로드 및 업데이트")
                .accessibilityLabel("새 버전 다운로드")
                .padding(.horizontal, 16)
            }
            }
            .background(.bar)
            Divider()
            CanvasHost(state: state)
            Divider()
            HStack {
                Label(state.tool.title, systemImage: state.tool.symbol)
                Text("·").foregroundStyle(.tertiary)
                Text(state.tool.hint)
                Spacer()
                Button { state.resetZoom?() } label: {
                    Text("\(Int((state.zoom * 100).rounded()))%")
                        .monospacedDigit()
                }.buttonStyle(.borderless).topTooltip("클릭하여 100%로 복원 · 두 손가락 핀치로 확대/축소")
                Text("·").foregroundStyle(.tertiary)
                Text("\(state.strokeCount)개 획")
                Text("·").foregroundStyle(.tertiary)
                Text("\(state.visiblePage) / \(state.workspacePageCount) 페이지 · " + (state.note.paperStyle == .grid ? "모눈" : "무지"))
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).frame(height: 30).background(.bar)
        }
        .frame(minWidth: 740, minHeight: 440)
        .sheet(isPresented: $state.showShortcuts) { ShortcutHelpView() }
        .sheet(isPresented: $state.showStickers) { StickerLibraryView(state:state) }
    }
}

/// Classic floppy disk, drawn as a vector for crisp light/dark appearance.
private struct FloppyDiskIcon: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: 13.5, y: 1.5))
            path.addLine(to: CGPoint(x: 16.5, y: 4.5))
            path.addLine(to: CGPoint(x: 16.5, y: 16.5))
            path.addLine(to: CGPoint(x: 1.5, y: 16.5))
            path.closeSubpath()
            path.move(to: CGPoint(x: 4.5, y: 1.5))
            path.addLine(to: CGPoint(x: 4.5, y: 6.5))
            path.addLine(to: CGPoint(x: 12.5, y: 6.5))
            path.addLine(to: CGPoint(x: 12.5, y: 1.5))
            path.move(to: CGPoint(x: 4.5, y: 16.5))
            path.addLine(to: CGPoint(x: 4.5, y: 10))
            path.addLine(to: CGPoint(x: 13.5, y: 10))
            path.addLine(to: CGPoint(x: 13.5, y: 16.5))
            path.move(to: CGPoint(x: 10, y: 3.2))
            path.addLine(to: CGPoint(x: 10, y: 4.8))
        }
        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// Native tab-role segmented bars own the connected glass track and moving lens.
struct DrawingToolStrip: View {
    @ObservedObject var state: NoteState
    private let tools: [InkTool] = [.pen,.eraser,.selection,.laser,.ellipse,.rectangle,.freeArrow,.arrow]
    private let help = ["볼펜 · P / F","획 지우개 · E","사각형 선택 · V","레이저 · L",
                        "원 / 타원 · C · ⌘ 정원","사각형 · R · ⌘ 정사각형","자유 화살표 · Q","화살표 · A"]
    var body: some View {
        NativeToolbarPicker(items:tools.indices.map { index in
            let tool = tools[index]
            return NativeToolbarItem(id:tool.symbol,image:NSImage(systemSymbolName:tool.symbol,accessibilityDescription:tool.title)!,help:help[index])
        },selected:tools.firstIndex { $0 == state.tool } ?? 0,label:"그리기 도구") { index in
            state.selectTool(tools[index])
        }
    }
}

struct ColorPresetStrip: View {
    @ObservedObject var state: NoteState
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        NativeToolbarPicker(items:preferences.colorPresets.map { preset in
            let color = NSColor(cgColor:preset.color.cgColor)!
            let image = NSImage(size:NSSize(width:24,height:24),flipped:false) { rect in
                color.setFill()
                NSBezierPath(ovalIn:rect.insetBy(dx:2.5,dy:2.5)).fill()
                return true
            }
            image.accessibilityDescription = preset.name + " 펜"
            let key = preset.key + ":" + [preset.color.red,preset.color.green,preset.color.blue,preset.color.alpha].map { String($0) }.joined(separator:",")
            return NativeToolbarItem(id:key,image:image,help:preset.name + " · " + preset.key)
        },selected:preferences.colorPresets.firstIndex { $0.color == state.color } ?? -1,label:"펜 색상") { index in
            state.color = preferences.colorPresets[index].color
        }
    }
}

private struct NativeToolbarItem {
    let id: String
    let image: NSImage
    let help: String
}

private struct NativeToolbarPicker: NSViewRepresentable {
    let items: [NativeToolbarItem]
    let selected: Int
    let label: String
    let onSelect: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect:onSelect) }
    func makeNSView(context:Context) -> ToolbarSegments {
        let control = ToolbarSegments()
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator; control.action = #selector(Coordinator.changed(_:))
        if #available(macOS 26.0, *) {
            control.prefersCompactControlSizeMetrics = false
            control.controlSize = .extraLarge; control.borderShape = .capsule
        } else { control.controlSize = .large }
        if #available(macOS 27.0, *) { control.role = .tabs }
        return control
    }
    func updateNSView(_ control:ToolbarSegments,context:Context) {
        context.coordinator.onSelect = onSelect
        control.configure(items)
        if control.selectedSegment != selected { control.selectedSegment = selected }
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:ToolbarSegments,context:Context) -> CGSize? {
        NSSize(width:CGFloat(items.count)*44,height:44)
    }
    @MainActor final class Coordinator:NSObject {
        var onSelect: (Int) -> Void
        init(onSelect:@escaping (Int) -> Void) { self.onSelect = onSelect }
        @objc func changed(_ sender:NSSegmentedControl) {
            guard (0..<sender.segmentCount).contains(sender.selectedSegment) else { return }
            onSelect(sender.selectedSegment)
        }
    }
    final class FullTargetSegmentCell:NSSegmentedCell {
        override func hitTest(for event:NSEvent,in cellFrame:NSRect,of controlView:NSView) -> NSCell.HitResult {
            if isEnabled, controlView.bounds.contains(controlView.convert(event.locationInWindow,from:nil)) {
                return [.contentArea,.trackableArea]
            }
            return super.hitTest(for:event,in:cellFrame,of:controlView)
        }
    }
    final class ToolbarSegments:NSSegmentedControl {
        override class var cellClass: AnyClass? {
            get { FullTargetSegmentCell.self }
            set {}
        }
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

        private var keys: [String] = []
        private var tips: [TooltipAnchorView] = []
        func configure(_ items:[NativeToolbarItem]) {
            guard keys != items.map(\.id) else { return }
            keys = items.map(\.id)
            tips.forEach { $0.hideTooltip(); $0.removeFromSuperview() }; tips.removeAll()
            segmentCount = items.count
            for (index,item) in items.enumerated() {
                setImage(item.image,forSegment:index)
                setImageScaling(.scaleProportionallyDown,forSegment:index)
                setWidth(0,forSegment:index)
                let tip = TooltipAnchorView(text:item.help)
                addSubview(tip); tips.append(tip)
            }
            needsLayout = true
        }
        override func layout() {
            super.layout()
            let width = bounds.width/CGFloat(max(segmentCount,1))
            for (index,tip) in tips.enumerated() {
                tip.frame = NSRect(x:CGFloat(index)*width,y:0,width:width,height:bounds.height)
            }
        }
    }
}

/// File/help/history actions share a spacious hover target without changing their actions.
private struct ToolbarActionButtonStyle: ButtonStyle {
    func makeBody(configuration:Configuration) -> some View { ActionLabel(configuration:configuration) }
    private struct ActionLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .foregroundStyle(.secondary)
                .padding(.horizontal,10)
                .frame(minWidth:40,minHeight:44)
                .background(RoundedRectangle(cornerRadius:10)
                    .fill(Color.primary.opacity(enabled ? (configuration.isPressed ? 0.15 : (hovering ? 0.08 : 0)) : 0)))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.38)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration:0.12),value:hovering)
                .animation(reduceMotion ? nil : .easeOut(duration:0.08),value:configuration.isPressed)
        }
    }
}

/// Glass is inset visually; the complete label remains a 44-point hit target.
private struct DrawingToolButtonStyle: ButtonStyle {
    let tint: Color
    var selected = false
    var springPress = false
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration:configuration,tint:tint,selected:selected,springPress:springPress)
    }
    private struct HoverLabel: View {
        let configuration: ButtonStyle.Configuration
        let tint: Color
        let selected: Bool
        let springPress: Bool
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        var body: some View {
            glassLabel
                .scaleEffect(x:springPress && !reduceMotion ? (configuration.isPressed ? 1.08 : (hovering ? 1.02 : 1)) : 1,
                             y:springPress && !reduceMotion ? (configuration.isPressed ? 1.12 : (hovering ? 1.02 : 1)) : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration:0.16),value:hovering)
                .animation(reduceMotion ? nil : .easeOut(duration:0.12),value:configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration:0.2),value:selected)
        }
        @ViewBuilder private var glassLabel: some View {
            if #available(macOS 26.0, *), !reduceTransparency {
                configuration.label.padding(-3)
                    .glassEffect((selected ? Glass.regular.tint(tint.opacity(0.2)) : Glass.regular).interactive(),
                                 in:RoundedRectangle(cornerRadius:12))
                    .overlay {
                        RoundedRectangle(cornerRadius:12)
                            .strokeBorder(tint.opacity(selected ? 0.55 : 0),lineWidth:1)
                    }.padding(3)
            } else {
                configuration.label.background {
                    RoundedRectangle(cornerRadius:12)
                        .fill(Color(nsColor:.controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius:12)
                            .fill(tint.opacity(configuration.isPressed ? 0.24 : (selected ? 0.18 : (hovering ? 0.1 : 0)))))
                        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(tint.opacity(selected ? 0.55 : 0.12),lineWidth:1))
                        .padding(3)
                }
            }
        }
    }
}

/// A child panel keeps the tip above its control, outside the horizontal scroll clip.
private struct TopTooltip: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> TooltipAnchorView { TooltipAnchorView(text: text) }
    func updateNSView(_ view: TooltipAnchorView, context: Context) { view.text = text }
    static func dismantleNSView(_ view: TooltipAnchorView, coordinator: ()) { view.hideTooltip() }
}
private extension View {
    func topTooltip(_ text: String) -> some View { background(TopTooltip(text: text)) }
}

@MainActor
final class TooltipAnchorView: NSView {
    var text: String { didSet { if oldValue != text { hideTooltip() } } }
    private(set) var tooltipWindow: NSPanel?
    private var area: NSTrackingArea?
    private var trackedRegion = CGRect.null
    init(text: String) { self.text = text; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        let region = convert(visibleRect,to:nil)
        if region != trackedRegion { hideTooltip(); trackedRegion = region }
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); self.area = area
        super.updateTrackingAreas()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        hideTooltip()
        NotificationCenter.default.removeObserver(self)
        if let newWindow {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(hideTooltip), name: name, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func mouseEntered(with event: NSEvent) { showTooltip() }
    override func mouseExited(with event: NSEvent) { hideTooltip() }
    func showTooltip() {
        guard tooltipWindow == nil, let window, window.isKeyWindow, !text.isEmpty,
              !visibleRect.isEmpty else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 20, height: label.frame.height + 12)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover; background.blendingMode = .behindWindow
        background.state = .active; background.wantsLayer = true
        background.layer?.cornerRadius = 6; background.layer?.masksToBounds = true
        label.setFrameOrigin(NSPoint(x: 10, y: 6)); background.addSubview(label)
        panel.contentView = background
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let screen = window.screen?.frame ?? anchor.insetBy(dx: -1000, dy: -1000)
        let x = max(screen.minX + 4, min(anchor.midX - size.width/2, screen.maxX - size.width - 4))
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.maxY + 6))
        tooltipWindow = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
    @objc func hideTooltip() {
        guard let panel = tooltipWindow else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil); panel.close(); tooltipWindow = nil
    }
}

private struct StickerActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration:configuration)
    }
    private struct Label: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(.system(size:13,weight:.medium))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .padding(.horizontal,12).padding(.vertical,8)
                .background(configuration.isPressed ? Color.accentColor.opacity(0.25) : Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:7))
                .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(Color.primary.opacity(0.15)))
                .opacity(enabled ? 1 : 0.45)
        }
    }
}

struct StickerLibraryView: View {
    @ObservedObject var state: NoteState
    @ObservedObject var library = StickerLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    private func attempt(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
    private func importImages() {
        let panel = NSOpenPanel()
        panel.title = "스티커 이미지 등록"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { attempt { try library.importImage(at:url) } }
        }
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Label("스티커",systemImage:"face.smiling").font(.title2.bold())
                Text("\(library.stickers.count)개").foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: { Image(systemName:"xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("스티커함 닫기")
            }.padding(20)
            HStack {
                Button("이미지 등록…",action:importImages)
                Button("클립보드 등록") {
                    attempt {
                        guard let data = NSPasteboard.general.data(forType:.png) ?? NSPasteboard.general.data(forType:.tiff) ?? NSImage(pasteboard:.general)?.tiffRepresentation else {
                            throw NSError(domain:"LightNote.Stickers",code:6,userInfo:[NSLocalizedDescriptionKey:"클립보드에 이미지가 없습니다."])
                        }
                        try library.add(data:data,name:"클립보드")
                    }
                }
                Button("선택 영역 등록") {
                    attempt {
                        guard let data = try state.stickerSelectionPNG?() else { return }
                        try library.add(data:data,name:"선택 영역")
                    }
                }.disabled(!state.hasSelection)
                Spacer()
            }.buttonStyle(StickerActionButtonStyle()).padding(.horizontal,20).padding(.bottom,16)
            Divider()
            if library.stickers.isEmpty {
                ContentUnavailableView("등록한 스티커가 없습니다",systemImage:"photo.on.rectangle",
                    description:Text("이미지나 클립보드를 등록해 사용하세요."))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:110),spacing:12)],spacing:12) {
                        ForEach(library.stickers) { sticker in
                            Button {
                                attempt {
                                    let data = try library.data(for:sticker)
                                    guard state.insertSticker?(data) == true else {
                                        throw NSError(domain:"LightNote.Stickers",code:7,userInfo:[NSLocalizedDescriptionKey:"스티커를 노트에 넣지 못했습니다."])
                                    }
                                    dismiss()
                                }
                            } label: {
                                VStack(spacing:8) {
                                    Image(nsImage:sticker.thumbnail).resizable().scaledToFit().frame(width:84,height:84)
                                    Text(sticker.name).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                }
                                .frame(maxWidth:.infinity).padding(10)
                                .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .topTooltip(sticker.name + " · 클릭하여 삽입")
                            .accessibilityLabel(sticker.name + " 스티커 삽입")
                            .contextMenu {
                                Button("스티커 삭제",role:.destructive) { attempt { try library.remove(sticker) } }
                            }
                        }
                    }.padding(20)
                }
            }
            Divider()
            Text("클릭하여 노트에 넣기 · 우클릭하여 스티커함에서 삭제")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width:640,height:480)
        .background(Color(nsColor:.windowBackgroundColor))
        .onAppear { library.reload(); errorMessage = library.loadError }
        .alert("스티커 오류",isPresented:Binding(get:{errorMessage != nil},set:{if !$0 {errorMessage = nil}})) {
            Button("확인") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct ShortcutHelpView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.dismiss) private var dismiss
    private func row(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 18) {
            Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(.primary)
                .frame(width: 100, alignment: .leading)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.font(.system(size: 13)).padding(.vertical, 3)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "keyboard").foregroundStyle(.tint)
                Text("단축키 도움말").font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .topTooltip("닫기 · Esc").accessibilityLabel("도움말 닫기")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("그리기 도구").font(.headline).padding(.bottom, 6)
                    row("P / F", "펜")
                    row("⇧ + 펜 드래그", "시작점부터 커서까지 직선 · 떼면 자유 필기")
                    row("E", "획 지우개")
                    row("V", "사각형 선택 · 내부 드래그로 이동")
                    row("L", "레이저 · 다시 누르면 복원, 떼면 1.3초간 사라짐")
                    row("C", "원 · 타원")
                    row("R", "사각형")
                    row("Q", "펜처럼 그리는 자유 화살표")
                    row("A", "화살표")
                    row("⌘ + 드래그", "원·사각형을 정원·정사각형으로 제한")
                    row("[ / ]", "펜 두께 감소 / 증가")
                    Divider().padding(.vertical, 12)
                    Text("편집과 문서").font(.headline).padding(.bottom, 6)
                    row("⌘ Z", "실행 취소")
                    row("⌘ ⇧ Z", "다시 실행")
                    row("⌘ C / ⌘ V", "선택한 획 복사 / 붙여넣기")
                    row("⌘ D", "선택한 획 복제")
                    row("⌫ / Delete", "선택한 획 삭제")
                    row("Esc", "선택 해제 · 도형 취소 · 도움말 닫기")
                    row("⌃ ⌘ C / ⌘ ⇧ E", "선택 영역 PNG 복사 / 내보내기")
                    row("⌘ 누르기", "객체 선택 · 빈 선택은 이전 도구로")
                    row("⌘ ,", "환경설정")
                    row("⌘ N", "새 노트")
                    row("⌘ O", "노트 열기")
                    row("⌘ S", "저장 · 평소에는 자동 저장")
                    row("⌘ ⇧ S", "다른 이름으로 저장")
                    row("⌃ ⌘ F", "전체 화면")
                    row("/", "단축키 도움말 열기")
                    Divider().padding(.vertical, 12)
                    Text("펜 색상").font(.headline).padding(.bottom, 6)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(preferences.colorPresets, id: \.key) { preset in
                            HStack(spacing: 12) {
                                Text(preset.key).font(.system(.body, design: .monospaced))
                                Circle().fill(Color(cgColor: preset.color.cgColor)).frame(width: 12, height: 12)
                                Text(preset.name).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider().padding(.vertical, 12)
                    Text("두 손가락 스크롤로 이동 · 핀치로 확대/축소\n선택 상자의 모서리를 드래그하면 크기 변경\n도구 단축키는 텍스트 입력 중에는 작동하지 않습니다.")
                        .font(.footnote).foregroundStyle(.secondary).lineSpacing(5)
                }.padding(24)
            }
        }.frame(width: 520, height: 560)
    }
}
