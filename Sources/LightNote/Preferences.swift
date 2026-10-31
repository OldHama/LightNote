import AppKit
import SwiftUI

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences(defaults: CommandLine.arguments.contains("--self-test")
        ? UserDefaults(suiteName: "com.lightnote.test." + UUID().uuidString)! : .standard)
    static let changed = Notification.Name("LightNotePreferencesChanged")
    static let defaultsKey = "LightNoteDrawingPreferences"
    nonisolated static let originalPresets: [(key: String, name: String, color: InkColor)] = [
        ("1", "검정", .black), ("2", "파랑", .blue), ("3", "빨강", .red), ("4", "초록", .green),
        ("5", "주황", InkColor(0.95, 0.43, 0.08)), ("6", "노랑", InkColor(0.85, 0.65, 0.02)),
        ("7", "보라", InkColor(0.52, 0.25, 0.78)), ("8", "분홍", InkColor(0.88, 0.27, 0.53)),
        ("9", "갈색", InkColor(0.48, 0.30, 0.18)), ("0", "회색", InkColor(0.45, 0.48, 0.52))
    ]
    private struct Stored: Codable {
        var penColor: InkColor = .black
        var penWidth: Double = 1.5
        var paper: PaperStyle = .grid
        var paperColor = InkColor(1, 0.985, 0.94)
        var gridColor = InkColor(0.78, 0.84, 0.91)
        var gridSpacing: Double = 20
        var palette = AppPreferences.originalPresets.map(\.color)
    }
    private let defaults: UserDefaults
    private var syncingUpdates = false
    @Published var penColor: InkColor { didSet { save("pen") } }
    @Published var penWidth: Double { didSet { save("pen") } }
    @Published var defaultPaper: PaperStyle { didSet { save("paper") } }
    @Published var paperColor: InkColor { didSet { save("paper") } }
    @Published var gridColor: InkColor { didSet { save("paper") } }
    @Published var gridSpacing: Double { didSet { save("paper") } }
    @Published var palette: [InkColor] { didSet { save("palette") } }
    @Published var automaticChecks: Bool { didSet { save("updates") } }
    @Published var automaticDownloads: Bool { didSet { save("updates") } }
    var colorPresets: [(key: String, name: String, color: InkColor)] {
        Self.originalPresets.enumerated().map { index, original in
            let color = palette[index]
            return (original.key, color == original.color ? original.name : "사용자 색상 " + original.key, color)
        }
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let stored: Stored
        if let decoded, Self.valid(decoded) { stored = decoded } else { stored = Stored() }
        penColor = stored.penColor; penWidth = stored.penWidth; defaultPaper = stored.paper
        paperColor = stored.paperColor; gridColor = stored.gridColor; gridSpacing = stored.gridSpacing
        palette = stored.palette
        automaticChecks = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        automaticDownloads = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
    }
    private static func valid(_ value: Stored) -> Bool {
        guard [0.5, 1, 1.5, 2, 3].contains(value.penWidth), (10...40).contains(value.gridSpacing),
              value.palette.count == 10 else { return false }
        return (value.palette + [value.penColor, value.paperColor, value.gridColor]).allSatisfy {
            [$0.red, $0.green, $0.blue, $0.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
    }
    func syncUpdateSettings(checks: Bool, downloads: Bool) {
        syncingUpdates = true
        automaticChecks = checks; automaticDownloads = downloads
        syncingUpdates = false
    }
    private func save(_ kind: String) {
        guard !syncingUpdates else { return }
        let value = Stored(penColor: penColor, penWidth: penWidth, paper: defaultPaper,
                           paperColor: paperColor, gridColor: gridColor, gridSpacing: gridSpacing, palette: palette)
        guard Self.valid(value), let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        if kind == "updates" {
            defaults.set(automaticChecks, forKey: "SUEnableAutomaticChecks")
            defaults.set(automaticDownloads, forKey: "SUAutomaticallyUpdate")
        }
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["kind": kind])
    }
    func resetDrawing() {
        let original = Stored()
        penColor = original.penColor; penWidth = original.penWidth; defaultPaper = original.paper
        paperColor = original.paperColor; gridColor = original.gridColor; gridSpacing = original.gridSpacing
        palette = original.palette
    }
}

struct PreferencesView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    private func color(_ read: @escaping () -> InkColor, _ write: @escaping (InkColor) -> Void) -> Binding<Color> {
        Binding(get: { Color(cgColor: read().cgColor) }, set: {
            guard let c = NSColor($0).usingColorSpace(.sRGB) else { return }
            write(InkColor(c.redComponent, c.greenComponent, c.blueComponent))
        })
    }
    var body: some View {
        TabView {
            Form {
                Section("펜 기본값") {
                    ColorPicker("펜 색상", selection: color({ preferences.penColor }, { preferences.penColor = $0 }), supportsOpacity: false)
                    Picker("펜 두께", selection: $preferences.penWidth) {
                        ForEach(NoteState.penWidths, id: \.self) { Text(String(format: "%.1f pt", $0)).tag($0) }
                    }
                    Text("열린 노트와 새 노트에서 새로 그리는 획에 적용됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("숫자 단축키 색상") {
                    ForEach(Array(AppPreferences.originalPresets.enumerated()), id: \.element.key) { index, preset in
                        ColorPicker("키 " + preset.key,
                            selection: color({ preferences.palette[index] }, { preferences.palette[index] = $0 }), supportsOpacity: false)
                    }
                }
            }.formStyle(.grouped).tabItem { Label("펜과 색상", systemImage: "pencil.tip") }
            Form {
                Section("새 노트") {
                    Picker("기본 용지", selection: $preferences.defaultPaper) {
                        Text("모눈").tag(PaperStyle.grid)
                        Text("무지").tag(PaperStyle.blank)
                    }
                }
                Section("모눈종이 모양") {
                    ColorPicker("종이 색상", selection: color({ preferences.paperColor }, { preferences.paperColor = $0 }), supportsOpacity: false)
                    ColorPicker("모눈 선 색상", selection: color({ preferences.gridColor }, { preferences.gridColor = $0 }), supportsOpacity: false)
                    Picker("모눈 간격", selection: $preferences.gridSpacing) {
                        ForEach([10.0, 15, 20, 25, 30, 40], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                    }
                    Text("모눈종이 모양은 열려 있는 모눈 노트에도 바로 적용됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                Button("그리기 설정을 기본값으로 복원") { preferences.resetDrawing() }
            }.formStyle(.grouped).tabItem { Label("용지", systemImage: "square.grid.3x3") }
            Form {
                Section("업데이트") {
                    Toggle("새 버전 자동 확인", isOn: $preferences.automaticChecks)
                    Toggle("업데이트 자동 다운로드 및 설치", isOn: $preferences.automaticDownloads)
                    Text("자동 업데이트는 앱 종료 시 적용됩니다.").font(.caption).foregroundStyle(.secondary)
                    Button("지금 업데이트 확인…") {
                        NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: NSApp.delegate, from: nil)
                    }
                }
            }.formStyle(.grouped).tabItem { Label("업데이트", systemImage: "arrow.down.circle") }
        }.padding(16).frame(minWidth: 480, idealWidth: 520, minHeight: 500, idealHeight: 560)
    }
}
