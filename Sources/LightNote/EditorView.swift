import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var state: NoteState
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
                    ForEach(NoteState.colorPresets, id: \.key) { preset in
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
                Label(state.tool == .pen ? "볼펜" : (state.tool == .selection ? "사각형 선택" : "획 지우개"), systemImage: state.tool == .pen ? "pencil.tip" : (state.tool == .selection ? "selection.pin.in.out" : "eraser"))
                Text("·").foregroundStyle(.tertiary)
                Text(state.tool == .pen ? "일정한 굵기" : (state.tool == .selection ? "영역 선택 후 안쪽을 드래그하여 이동" : "닿은 획 전체 삭제"))
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
    }
}
