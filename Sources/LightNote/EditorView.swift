import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var state: NoteState
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Button { NSDocumentController.shared.newDocument(nil) } label: { Image(systemName: "doc.badge.plus") }
                        .help("새 노트 · ⌘N").accessibilityLabel("새 노트")
                    Button { NSDocumentController.shared.openDocument(nil) } label: { Image(systemName: "folder") }
                        .help("열기 · ⌘O").accessibilityLabel("열기")
                    Button { state.finishInput?(); state.document?.save(nil) } label: { Image(systemName: "square.and.arrow.down") }
                        .help("저장 · ⌘S").accessibilityLabel("저장")
                    Button {
                        NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: NSApp.delegate, from: nil)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(Color.accentColor)
                    }.help("새 버전 다운로드 및 업데이트").accessibilityLabel("업데이트 다운로드")
                    Button { state.showShortcuts = true } label: {
                        Image(systemName: "questionmark.circle")
                    }.help("단축키 도움말 · /").accessibilityLabel("단축키 도움말")
                    Divider().frame(height: 22)
                    Button { state.document?.undoInk(nil) } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!state.canUndo).help("실행 취소 · ⌘Z").accessibilityLabel("실행 취소")
                    Button { state.document?.redoInk(nil) } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!state.canRedo).help("다시 실행 · ⌘⇧Z").accessibilityLabel("다시 실행")
                    Divider().frame(height: 22)
                    Button { state.selectTool(.pen) } label: {
                        Image(systemName: "pencil.tip")
                            .foregroundStyle(state.tool == .pen ? Color.accentColor : .secondary)
                    }.help("볼펜 · P").accessibilityLabel("볼펜")
                    Button { state.selectTool(.eraser) } label: {
                        Image(systemName: "eraser")
                            .foregroundStyle(state.tool == .eraser ? Color.accentColor : .secondary)
                    }.help("획 지우개 · E").accessibilityLabel("획 지우개")
                    Button { state.selectTool(.selection) } label: {
                        Image(systemName: "selection.pin.in.out")
                            .foregroundStyle(state.tool == .selection ? Color.accentColor : .secondary)
                    }.help("사각형 선택 · V").accessibilityLabel("사각형 선택")
                    Button { state.selectTool(.laser) } label: {
                        Image(systemName: "dot.scope")
                            .foregroundStyle(state.tool == .laser ? Color.red : .secondary)
                    }.help("레이저 · L").accessibilityLabel("레이저")
                    Button { state.selectTool(.ellipse) } label: {
                        Image(systemName: "circle")
                            .foregroundStyle(state.tool == .ellipse ? Color.accentColor : .secondary)
                    }.help("원 / 타원 · C · ⌘ 정원").accessibilityLabel("원 / 타원")
                    Button { state.selectTool(.rectangle) } label: {
                        Image(systemName: "rectangle")
                            .foregroundStyle(state.tool == .rectangle ? Color.accentColor : .secondary)
                    }.help("사각형 · R · ⌘ 정사각형").accessibilityLabel("사각형")
                    Button { state.selectTool(.arrow) } label: {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(state.tool == .arrow ? Color.accentColor : .secondary)
                    }.help("화살표 · A").accessibilityLabel("화살표")
                    ForEach(preferences.colorPresets, id: \.key) { preset in
                        Button { state.color = preset.color } label: {
                            Circle().fill(Color(cgColor: preset.color.cgColor)).frame(width: 19, height: 19)
                                .padding(4)
                                .overlay(Circle().stroke(state.color == preset.color ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain).help(preset.name + " · " + preset.key).accessibilityLabel(preset.name + " 펜")
                    }
                    ColorPicker("색상", selection: Binding(get: { Color(cgColor: state.color.cgColor) }, set: {
                        guard let c = NSColor($0).usingColorSpace(.sRGB) else { return }
                        state.color = InkColor(c.redComponent, c.greenComponent, c.blueComponent)
                    }), supportsOpacity: false).labelsHidden().help("사용자 지정 색상")
                    Picker("두께", selection: $state.width) {
                        ForEach(NoteState.penWidths, id: \.self) { width in
                            Text(String(format: "%.1f pt", width)).tag(width)
                        }
                    }.frame(width: 110).labelsHidden().help("펜 두께 · [ 얇게 / ] 두껍게")
                    Divider().frame(height: 22)
                    Picker("용지", selection: Binding(
                        get: { state.note.paperStyle },
                        set: { state.document?.setPaperStyle($0) }
                    )) {
                        Text("무지").tag(PaperStyle.blank)
                        Text("모눈").tag(PaperStyle.grid)
                    }.frame(width: 120).help("용지 유형 · 무지 / 모눈")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 18).frame(height: 58)
            }
            .frame(height: 58)
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
                }.buttonStyle(.borderless).help("클릭하여 100%로 복원 · 두 손가락 핀치로 확대/축소")
                Text("·").foregroundStyle(.tertiary)
                Text("\(state.strokeCount)개 획")
                Text("·").foregroundStyle(.tertiary)
                Text(state.note.paperStyle == .grid ? "모눈 · 확장 캔버스" : "무지 · 확장 캔버스")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).frame(height: 30).background(.bar)
        }
        .frame(minWidth: 740, minHeight: 440)
        .sheet(isPresented: $state.showShortcuts) { ShortcutHelpView() }
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
                    .help("닫기 · Esc").accessibilityLabel("도움말 닫기")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("그리기 도구").font(.headline).padding(.bottom, 6)
                    row("P", "펜")
                    row("E", "획 지우개")
                    row("V", "사각형 선택 · 내부 드래그로 이동")
                    row("L", "레이저 · 다시 누르면 복원, 떼면 2초간 사라짐")
                    row("C", "원 · 타원")
                    row("R", "사각형")
                    row("A", "화살표")
                    row("⌘ + 드래그", "원·사각형을 정원·정사각형으로 제한")
                    row("[ / ]", "펜 두께 감소 / 증가")
                    Divider().padding(.vertical, 12)
                    Text("편집과 문서").font(.headline).padding(.bottom, 6)
                    row("⌘ Z", "실행 취소")
                    row("⌘ ⇧ Z", "다시 실행")
                    row("⌫ / Delete", "선택한 획 삭제")
                    row("Esc", "선택 해제 · 도형 취소 · 도움말 닫기")
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
