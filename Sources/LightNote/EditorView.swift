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
                    Button { NSDocumentController.shared.newDocument(nil) } label: { Image(systemName: "doc.badge.plus") }
                        .topTooltip("새 노트 · ⌘N").accessibilityLabel("새 노트")
                    Button { NSDocumentController.shared.openDocument(nil) } label: { Image(systemName: "folder") }
                        .topTooltip("열기 · ⌘O").accessibilityLabel("열기")
                    Button { state.finishInput?(); state.document?.save(nil) } label: { FloppyDiskIcon() }
                        .topTooltip("저장 · ⌘S").accessibilityLabel("저장")
                    Button { state.showShortcuts = true } label: {
                        Image(systemName: "questionmark.circle")
                    }.topTooltip("단축키 도움말 · /").accessibilityLabel("단축키 도움말")
                    Divider().frame(height: 22)
                    Button { state.document?.undoInk(nil) } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!state.canUndo).topTooltip("실행 취소 · ⌘Z").accessibilityLabel("실행 취소")
                    Button { state.document?.redoInk(nil) } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!state.canRedo).topTooltip("다시 실행 · ⌘⇧Z").accessibilityLabel("다시 실행")
                    Divider().frame(height: 22)
                    DrawingToolStrip(state: state)
                    Button { state.showStickers = true } label: { Label("스티커",systemImage:"face.smiling") }
                        .topTooltip("등록한 스티커 사용").accessibilityLabel("스티커함")
                    Button { state.copySelectionPNG?() } label: { Image(systemName: "photo.on.rectangle") }
                        .disabled(!state.hasSelection).topTooltip("선택 영역 PNG 복사 · ⌃⌘C").accessibilityLabel("선택 영역 PNG 복사")
                    Button { state.exportSelectionPNG?() } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(!state.hasSelection).topTooltip("선택 영역 PNG 내보내기 · ⌘⇧E").accessibilityLabel("선택 영역 PNG 내보내기")
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

/// Contiguous full-size targets: the padding belongs to each Button's label.
struct DrawingToolStrip: View {
    @ObservedObject var state: NoteState
    private func tool(_ value: InkTool, help: String) -> some View {
        Button { state.selectTool(value) } label: {
            Image(systemName: value.symbol)
                .foregroundStyle(state.tool == value ? (value == .laser ? Color.red : Color.accentColor) : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(DrawingToolButtonStyle(tint: value == .laser ? .red : .accentColor))
        .topTooltip(help)
        .accessibilityLabel(value.title)
    }
    var body: some View {
        HStack(spacing: 0) {
            tool(.pen, help: "볼펜 · P")
            tool(.eraser, help: "획 지우개 · E")
            tool(.selection, help: "사각형 선택 · V")
            tool(.laser, help: "레이저 · L")
            tool(.ellipse, help: "원 / 타원 · C · ⌘ 정원")
            tool(.rectangle, help: "사각형 · R · ⌘ 정사각형")
            tool(.freeArrow, help: "자유 화살표 · Q")
            tool(.arrow, help: "화살표 · A")
        }
    }
}

/// Color swatches share the drawing tools' full-size targets and hover feedback.
struct ColorPresetStrip: View {
    @ObservedObject var state: NoteState
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        HStack(spacing: 0) {
            ForEach(preferences.colorPresets, id: \.key) { preset in
                Button { state.color = preset.color } label: {
                    Circle().fill(Color(cgColor: preset.color.cgColor))
                        .frame(width: 19, height: 19)
                        .padding(4)
                        .overlay(Circle().stroke(state.color == preset.color ? Color.accentColor : .clear, lineWidth: 2))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DrawingToolButtonStyle(tint: .accentColor))
                .topTooltip(preset.name + " · " + preset.key)
                .accessibilityLabel(preset.name + " 펜")
            }
        }
    }
}

/// Keep the complete 44-point hit target; inset only the visual highlight.
private struct DrawingToolButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, tint: tint)
    }
    private struct HoverLabel: View {
        let configuration: ButtonStyle.Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(configuration.isPressed ? 0.24 : (hovering ? 0.13 : 0)))
                        .padding(3)
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
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
                    row("P", "펜")
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
