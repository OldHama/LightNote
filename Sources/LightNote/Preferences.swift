import AppKit
import SwiftUI
import ImageIO

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences(defaults: CommandLine.arguments.contains("--self-test")
        ? UserDefaults(suiteName: "com.lightnote.test." + UUID().uuidString)! : .standard)
    static let changed = Notification.Name("LightNotePreferencesChanged")
    static let defaultsKey = "LightNoteDrawingPreferences"
    static let appearanceKey = "LightNoteAppearanceMode"
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "시스템 설정 따르기"
            case .light: "라이트 모드"
            case .dark: "나이트 모드"
            }
        }
        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named:.aqua)
            case .dark: NSAppearance(named:.darkAqua)
            }
        }
    }

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
    @Published private(set) var shortcutKeys: [String:String] = [:]
    static let shortcutsKey = "LightNoteDrawingShortcuts"
    func shortcutKey(_ action:DrawingShortcut) -> String { shortcutKeys[action.rawValue] ?? action.defaultKey }
    func shortcutLabel(_ action:DrawingShortcut) -> String { shortcutKey(action).uppercased() }
    func shortcutAction(for event:NSEvent) -> DrawingShortcut? {
        guard let key = DrawingShortcut.key(for:event) else { return nil }
        return DrawingShortcut.allCases.first { shortcutKey($0) == key }
    }
    @discardableResult func setShortcut(_ action:DrawingShortcut,key:String) -> String? {
        guard DrawingShortcut.availableKeys.contains(key) else { return "사용할 수 없는 키입니다." }
        if let other = DrawingShortcut.allCases.first(where:{ $0 != action && shortcutKey($0) == key }) {
            return key.uppercased() + " 키는 ‘" + other.title + "’에서 사용 중입니다."
        }
        shortcutKeys[action.rawValue] = key
        defaults.set(shortcutKeys,forKey:Self.shortcutsKey)
        return nil
    }
    func resetShortcuts() { shortcutKeys = [:]; defaults.removeObject(forKey:Self.shortcutsKey) }
    func resetColors() { penColor = .black; palette = Self.originalPresets.map(\.color) }
    private let defaults: UserDefaults
    private var syncingUpdates = false
    @Published var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue,forKey:Self.appearanceKey)
            NotificationCenter.default.post(name:Self.changed,object:self,userInfo:["kind":"appearance"])
        }
    }
    func applyAppearance() { NSApp.appearance = appearanceMode.appearance }
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
            return (shortcutKey(DrawingShortcut(rawValue:"color"+original.key)!), color == original.color ? original.name : "사용자 색상 " + original.key, color)
        }
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        appearanceMode = AppearanceMode(rawValue:defaults.string(forKey:Self.appearanceKey) ?? "") ?? .system
        let decoded = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let stored: Stored
        if let decoded, Self.valid(decoded) { stored = decoded } else { stored = Stored() }
        penColor = stored.penColor; penWidth = stored.penWidth; defaultPaper = stored.paper
        paperColor = stored.paperColor; gridColor = stored.gridColor; gridSpacing = stored.gridSpacing
        palette = stored.palette
        if let saved = defaults.dictionary(forKey:Self.shortcutsKey) as? [String:String] {
            let resolved = DrawingShortcut.allCases.map { saved[$0.rawValue] ?? $0.defaultKey }
            if resolved.allSatisfy({ DrawingShortcut.availableKeys.contains($0) }), Set(resolved).count == resolved.count {
                shortcutKeys = saved.filter { DrawingShortcut(rawValue:$0.key) != nil }
            }
        }
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
                Section("앱 모양") {
                    Picker("모드",selection:$preferences.appearanceMode) {
                        ForEach(AppPreferences.AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.pickerStyle(.radioGroup)
                }
            }.formStyle(.grouped).tabItem { Label("모양",systemImage:"circle.lefthalf.filled") }
            Form {
                Section("펜 기본값") {
                    ColorPicker("펜 색상", selection: color({ preferences.penColor }, { preferences.penColor = $0 }), supportsOpacity: false)
                    Picker("펜 두께", selection: $preferences.penWidth) {
                        ForEach(NoteState.penWidths, id: \.self) { Text(String(format: "%.1f pt", $0)).tag($0) }
                    }
                    Text("열린 노트와 새 노트에서 새로 그리는 획에 적용됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("단축키 색상") {
                    ForEach(Array(AppPreferences.originalPresets.enumerated()), id: \.element.key) { index, preset in
                        ColorPicker("키 " + preferences.shortcutLabel(DrawingShortcut(rawValue:"color"+preset.key)!),
                            selection: color({ preferences.palette[index] }, { preferences.palette[index] = $0 }), supportsOpacity: false)
                    }
                }
                Button("색상을 기본값으로 초기화") { preferences.resetColors() }
            }.formStyle(.grouped).tabItem { Label("펜과 색상", systemImage: "pencil.tip") }
            ShortcutPreferencesView(preferences:preferences)
                .tabItem { Label("단축키",systemImage:"keyboard") }
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

// Registered stickers are independent of notes; inserted copies embed their PNG.
@MainActor
final class StickerLibrary: ObservableObject {
    struct Sticker: Identifiable {
        let id: String
        let name: String
        let thumbnail: NSImage
    }
    static let shared = StickerLibrary(directory: RecoveryLocations.parent.appendingPathComponent("Stickers"))
    let directory: URL
    @Published private(set) var stickers: [Sticker] = []
    @Published private(set) var loadError: String?
    init(directory: URL) { self.directory = directory; reload() }
    func reload() {
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else { stickers = []; loadError = nil; return }
            let urls = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.creationDateKey],options:.skipsHiddenFiles)
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            stickers = urls.compactMap { url in
                guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(source,0,[
                        kCGImageSourceCreateThumbnailFromImageAlways:true,
                        kCGImageSourceCreateThumbnailWithTransform:true,
                        kCGImageSourceThumbnailMaxPixelSize:200] as CFDictionary) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent.components(separatedBy:"__").dropLast().joined(separator:"__")
                return Sticker(id:url.lastPathComponent,name:name.isEmpty ? "스티커" : name,thumbnail:NSImage(cgImage:thumb,size:.zero))
            }
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }
    @discardableResult
    func add(data: Data, name: String) throws -> Sticker {
        guard data.count <= 50_000_000,
              let source = CGImageSourceCreateWithData(data as CFData,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue*height.doubleValue <= 32_000_000,
              CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:200] as CFDictionary) != nil else {
            throw NSError(domain:"LightNote.Stickers",code:1,userInfo:[NSLocalizedDescriptionKey:"이미지를 읽을 수 없거나 너무 큽니다. 50MB·3,200만 픽셀 이하의 이미지를 선택해 주세요."])
        }
        let png: Data
        if data.starts(with:[137,80,78,71,13,10,26,10]) { png = data }
        else {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                    kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,
                    kCGImageSourceThumbnailMaxPixelSize:max(width.intValue,height.intValue)] as CFDictionary),
                  let encoded = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {
                throw NSError(domain:"LightNote.Stickers",code:2,userInfo:[NSLocalizedDescriptionKey:"스티커 이미지를 변환하지 못했습니다."])
            }
            png = encoded
        }
        guard png.count <= 50_000_000 else {
            throw NSError(domain:"LightNote.Stickers",code:3,userInfo:[NSLocalizedDescriptionKey:"변환한 이미지가 너무 큽니다. 더 작은 이미지를 선택해 주세요."])
        }
        let title = String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40))
            .replacingOccurrences(of:"/",with:" ").replacingOccurrences(of:":",with:" ")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let id = (title.isEmpty ? "스티커" : title) + "__" + UUID().uuidString + ".png"
        let url = directory.appendingPathComponent(id)
        try RecoveryJournal.durableWrite(png,to:url)
        reload()
        guard let item = stickers.first(where:{$0.id == id}) else {
            throw NSError(domain:"LightNote.Stickers",code:4,userInfo:[NSLocalizedDescriptionKey:"등록한 스티커를 표시하지 못했습니다."])
        }
        return item
    }
    func importImage(at url: URL) throws {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 50_000_000 else {
            throw NSError(domain:"LightNote.Stickers",code:5,userInfo:[NSLocalizedDescriptionKey:"50MB 이하의 이미지로 등록해 주세요."])
        }
        try add(data:Data(contentsOf:url),name:url.deletingPathExtension().lastPathComponent)
    }
    func data(for sticker: Sticker) throws -> Data {
        guard stickers.contains(where:{$0.id == sticker.id}) else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf:directory.appendingPathComponent(sticker.id))
    }
    func remove(_ sticker: Sticker) throws {
        guard stickers.contains(where:{$0.id == sticker.id}) else { return }
        try FileManager.default.removeItem(at:directory.appendingPathComponent(sticker.id))
        reload()
    }
}
