import AppKit
import SwiftUI

/// Physical keys preserve drawing shortcuts while a Korean input source is active.
enum DrawingShortcut: String, CaseIterable, Identifiable {
    case pen, penAlternate, eraser, selection, laser, ellipse, rectangle, freeArrow, arrow, thinner, thicker, help
    case color1, color2, color3, color4, color5, color6, color7, color8, color9, color0
    var id: String { rawValue }
    var defaultKey: String {
        switch self {
        case .pen: "p"; case .penAlternate: "f"; case .eraser: "e"; case .selection: "v"
        case .laser: "l"; case .ellipse: "c"; case .rectangle: "r"; case .freeArrow: "q"; case .arrow: "a"
        case .thinner: "["; case .thicker: "]"; case .help: "/"
        default: String(rawValue.suffix(1))
        }
    }
    var title: String {
        switch self {
        case .pen: "펜"; case .penAlternate: "펜 보조 단축키"; case .eraser: "획 지우개"; case .selection: "객체 선택"
        case .laser: "레이저"; case .ellipse: "원 / 타원"; case .rectangle: "사각형"; case .freeArrow: "자유 화살표"; case .arrow: "화살표"
        case .thinner: "펜 두께 감소"; case .thicker: "펜 두께 증가"; case .help: "단축키 도움말"
        default: "색상 " + defaultKey
        }
    }
    var tool: InkTool? {
        switch self {
        case .pen, .penAlternate: .pen; case .eraser: .eraser; case .selection: .selection
        case .laser: .laser; case .ellipse: .ellipse; case .rectangle: .rectangle; case .freeArrow: .freeArrow; case .arrow: .arrow
        default: nil
        }
    }
    static let physical: [UInt16:String] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",32:"u",33:"[",34:"i",35:"p",37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",43:",",44:"/",45:"n",46:"m",47:".",50:"`"]
    static let availableKeys = Array(Set(physical.values)).sorted()
    static func key(for event:NSEvent) -> String? { physical[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() }
}

struct ShortcutPreferencesView: View {
    @ObservedObject var preferences: AppPreferences
    @State private var conflict: String?
    var body: some View {
        Form {
            Section("그리기 단축키") {
                ForEach(DrawingShortcut.allCases) { action in
                    Picker(action.title, selection:Binding(get:{ preferences.shortcutKey(action) },set:{ key in
                        conflict = preferences.setShortcut(action,key:key)
                    })) {
                        ForEach(DrawingShortcut.availableKeys,id:\.self) { key in Text(key.uppercased()).tag(key) }
                    }
                }
            }
            if let conflict { Text(conflict).foregroundStyle(.red).accessibilityLabel(conflict) }
            Button("단축키를 기본값으로 복원") { preferences.resetShortcuts(); conflict = nil }
            Text("⌘C·⌘V·⌘Z 등 편집 단축키와 Esc·Delete는 기존대로 사용합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
