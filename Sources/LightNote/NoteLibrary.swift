import AppKit
import SwiftUI
import ImageIO

@MainActor
final class NoteLibrary: ObservableObject {
    struct Card: Identifiable {
        let url: URL
        let modified: Date
        var preview: Data?
        var unreadable = false
        var id: String { url.path }
        @MainActor var name: String { NoteWindowController.readableTitle(for:url) }
    }
    enum Sort: String, CaseIterable { case recent = "최근 수정순", name = "이름순" }
    static let shared = NoteLibrary(root:RecoveryLocations.copies,defaults:.standard)
    let root: URL
    let defaults: UserDefaults
    private let trash: (URL) throws -> Void
    @Published private(set) var cards: [Card] = []
    @Published private(set) var folders: [URL] = []
    @Published var directory: URL {
        didSet {
            let normalized = directory.standardizedFileURL
            if normalized != directory { directory = normalized }
        }
    }
    @Published var query = ""
    @Published var sort = Sort.recent
    @Published var favoritesOnly = false
    @Published private(set) var favorites: Set<String>
    @Published private(set) var loading = false
    @Published var busy = false
    @Published var errorMessage: String?
    var didOpenNote: (() -> Void)?
    private var renderTask: Task<Void,Never>?
    private var generation = UUID()
    init(root: URL, defaults: UserDefaults, trash: ((URL) throws -> Void)? = nil) {
        self.root = root.standardizedFileURL; self.directory = root.standardizedFileURL
        self.defaults = defaults
        self.favorites = Set(defaults.stringArray(forKey:"LightNoteFavoriteNotes") ?? [])
        self.trash = trash ?? { url in try FileManager.default.trashItem(at:url,resultingItemURL:nil) }
    }
    var visibleCards: [Card] {
        cards.filter { card in
            let locationMatches = !query.isEmpty || favoritesOnly || card.url.deletingLastPathComponent().path == directory.path ||
                (directory.path == root.path && !card.url.path.hasPrefix(root.path + "/"))
            return locationMatches && (!favoritesOnly || favorites.contains(card.id)) &&
                (query.isEmpty || card.name.localizedCaseInsensitiveContains(query))
        }.sorted { a,b in
            if sort == .name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    var visibleFolders: [URL] {
        guard query.isEmpty, !favoritesOnly else { return [] }
        return folders.filter { $0.deletingLastPathComponent().path == directory.path }
    }
    var pathTitle: String {
        directory.path == root.path ? "모든 노트" : directory.path.replacingOccurrences(of:root.path + "/",with:"")
    }
    func toggleFavorite(_ url: URL) {
        if !favorites.insert(url.path).inserted { favorites.remove(url.path) }
        defaults.set(Array(favorites),forKey:"LightNoteFavoriteNotes")
    }
    func refresh(onlyIfChanged: Bool = false) {
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            var files = Set<URL>(); var directories: [URL] = []
            if let enumerator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:.skipsHiddenFiles) {
                for case let url as URL in enumerator {
                    let values = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if values.isDirectory == true { directories.append(url.standardizedFileURL) }
                    else if url.pathExtension == "lightnote" { files.insert(url.standardizedFileURL) }
                }
            }
            if !CommandLine.arguments.contains("--self-test") {
                for url in NSDocumentController.shared.recentDocumentURLs where url.pathExtension == "lightnote" { files.insert(url.standardizedFileURL) }
                for document in NSDocumentController.shared.documents { if let url = document.fileURL { files.insert(url.standardizedFileURL) } }
            }
            let previous = Dictionary(uniqueKeysWithValues:cards.map { ($0.id,$0) })
            let nextCards = files.compactMap { url -> Card? in
                guard let values = try? url.resourceValues(forKeys:[.contentModificationDateKey,.isRegularFileKey]), values.isRegularFile == true else { return nil }
                let date = values.contentModificationDate ?? .distantPast
                return Card(url:url,modified:date,preview:previous[url.path]?.modified == date ? previous[url.path]?.preview : nil)
            }
            let nextFolders = directories.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            if onlyIfChanged, nextCards.count == cards.count, nextFolders == folders,
               nextCards.allSatisfy({ previous[$0.id]?.modified == $0.modified }),
               FileManager.default.fileExists(atPath:directory.path) { return }
            renderTask?.cancel()
            let token = UUID(); generation = token
            cards = nextCards; folders = nextFolders
            if !FileManager.default.fileExists(atPath:directory.path) { directory = root }
            let jobs = cards
            let paper = AppPreferences.shared.paperColor
            let grid = AppPreferences.shared.gridColor
            let spacing = AppPreferences.shared.gridSpacing
            loading = !jobs.isEmpty
            renderTask = Task { [weak self] in
                for card in jobs {
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    let snapshot = (NSDocumentController.shared.document(for:card.url) as? NoteDocument)?.state.note
                    if card.preview != nil && snapshot == nil { continue }
                    let result = await Task.detached(priority:.utility) { () -> (Data?,Bool) in
                        do {
                            let note: NoteFile
                            if let snapshot { note = snapshot }
                            else { note = try NoteFile.decode(Data(contentsOf:card.url)) }
                            return (Self.renderPreview(note,paper:paper,grid:grid,spacing:spacing),false)
                        } catch { return (nil,true) }
                    }.value
                    guard !Task.isCancelled, self.generation == token else { return }
                    if let index = self.cards.firstIndex(where:{$0.id == card.id}) {
                        self.cards[index].preview = result.0; self.cards[index].unreadable = result.1
                    }
                }
                if let self, self.generation == token { self.loading = false }
            }
        } catch { loading = false; errorMessage = error.localizedDescription }
    }
    func waitForPreviews() async { await renderTask?.value }
    private func checkedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              !name.contains("\n"), name.utf8.count <= 180 else {
            throw NSError(domain:"LightNote.Library",code:1,userInfo:[NSLocalizedDescriptionKey:"이름을 입력해 주세요. /, :, 줄바꿈은 사용할 수 없습니다."])
        }
        return name
    }
    private func openDocument(_ url: URL) -> NoteDocument? { NSDocumentController.shared.document(for:url) as? NoteDocument }
    private func uniqueURL(name: String, directory: URL) -> URL {
        var suffix = 1
        var url = directory.appendingPathComponent(name + ".lightnote")
        while FileManager.default.fileExists(atPath:url.path) {
            suffix += 1; url = directory.appendingPathComponent(name + " \(suffix).lightnote")
        }
        return url
    }
    func createFolder(name: String) throws {
        let url = directory.appendingPathComponent(try checkedName(name),isDirectory:true)
        guard !FileManager.default.fileExists(atPath:url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        refresh()
    }
    enum Template { case blank, studentConsultation }
    func createNote(template: Template = .blank) async throws {
        let note = NoteDocument()
        if template == .studentConsultation {
            note.state.note = try StudentConsultationTemplate.makeNote()
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            note.fileURL = uniqueURL(name:"학생 신규 상담",directory:directory)
        }
        NSDocumentController.shared.addDocument(note)
        do {
            try await note.persistLatest(directory:directory)
            note.state.refresh()
            note.makeWindowControllers()
            note.showWindows(); refresh()
            didOpenNote?()
        } catch { note.updateChangeCount(.changeCleared); note.close(); throw error }
    }
    func open(_ card: Card) {
        NSDocumentController.shared.openDocument(withContentsOf:card.url,display:true) { [weak self] document,_,error in
            if let error { NSApp.presentError(error) }
            else if document != nil { self?.didOpenNote?() }
        }
    }
    func rename(_ card: Card, to name: String) async throws {
        let stem = try checkedName(name.hasSuffix(".lightnote") ? String(name.dropLast(10)) : name)
        try await move(card,to:card.url.deletingLastPathComponent().appendingPathComponent(stem + ".lightnote"))
    }
    func move(_ card: Card, to destination: URL) async throws {
        guard destination != card.url else { return }
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw CocoaError(.fileWriteFileExists) }
        if let document = openDocument(card.url) {
            try await document.persistLatest()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                document.move(to:destination) { error in
                    if let error { continuation.resume(throwing:error) } else { continuation.resume() }
                }
            }
            try document.libraryDidMove(from:card.url)
        } else {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?; var moveError: Error?
            coordinator.coordinate(writingItemAt:card.url,options:.forMoving,error:&coordinationError) { source in
                do { try FileManager.default.moveItem(at:source,to:destination) } catch { moveError = error }
            }
            if let error = coordinationError ?? moveError as NSError? { throw error }
        }
        if favorites.remove(card.id) != nil { favorites.insert(destination.path); defaults.set(Array(favorites),forKey:"LightNoteFavoriteNotes") }
        if defaults.string(forKey:LightNoteDocumentController.lastDocumentKey) == card.id {
            defaults.set(destination.path,forKey:LightNoteDocumentController.lastDocumentKey)
        }
        if !CommandLine.arguments.contains("--self-test") { NSDocumentController.shared.noteNewRecentDocumentURL(destination) }
        refresh()
    }
    @discardableResult func duplicate(_ card: Card) async throws -> URL {
        if let document = openDocument(card.url) { try await document.persistLatest() }
        let destination = uniqueURL(name:card.name + " 사본",directory:card.url.deletingLastPathComponent())
        try await Task.detached(priority:.utility) {
            try FileManager.default.copyItem(at:card.url,to:destination)
        }.value
        refresh(); return destination
    }
    func delete(_ card: Card) async throws {
        if let document = openDocument(card.url) { try await document.persistLatest(); document.close() }
        try trash(card.url)
        favorites.remove(card.id); defaults.set(Array(favorites),forKey:"LightNoteFavoriteNotes")
        if defaults.string(forKey:LightNoteDocumentController.lastDocumentKey) == card.id { defaults.removeObject(forKey:LightNoteDocumentController.lastDocumentKey) }
        refresh()
    }
    nonisolated private static func renderPreview(_ note: NoteFile, paper: InkColor, grid: InkColor, spacing: Double) -> Data? {
        let width = 230, height = 310
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(Double(width)/note.pageWidth,Double(height)/note.pageHeight)
        context.setFillColor(note.paperStyle == .grid ? paper.cgColor : NSColor.white.cgColor)
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.translateBy(x:0,y:CGFloat(height)); context.scaleBy(x:scale,y:-scale)
        let page = CGRect(x:0,y:0,width:Double(width)/scale,height:Double(height)/scale)
        if note.paperStyle == .grid {
            let step = spacing * max(1,ceil(5/(spacing*scale)))
            context.setStrokeColor(grid.cgColor); context.setLineWidth(0.4/scale)
            for x in stride(from:0.0,through:page.maxX,by:step) { context.move(to:CGPoint(x:x,y:0)); context.addLine(to:CGPoint(x:x,y:page.maxY)) }
            for y in stride(from:0.0,through:page.maxY,by:step) { context.move(to:CGPoint(x:0,y:y)); context.addLine(to:CGPoint(x:page.maxX,y:y)) }
            context.strokePath()
        }
        context.setLineCap(.round); context.setLineJoin(.round)
        for stroke in note.strokes where stroke.bounds.intersects(page) {
            if stroke.tool == "image", let data = stroke.imagePNG, let source = CGImageSourceCreateWithData(data as CFData,nil),
               let image = CGImageSourceCreateImageAtIndex(source,0,nil), stroke.samples.count == 2 {
                let a = stroke.samples[0].point, b = stroke.samples[1].point
                context.saveGState(); context.translateBy(x:min(a.x,b.x),y:max(a.y,b.y)); context.scaleBy(x:1,y:-1)
                context.draw(image,in:CGRect(x:0,y:0,width:abs(b.x-a.x),height:abs(b.y-a.y))); context.restoreGState()
            } else {
                context.setStrokeColor(stroke.color.cgColor); context.setFillColor(stroke.color.cgColor)
                context.setLineWidth(max(stroke.width,0.6/scale))
                if let point = stroke.samples.first?.point, stroke.samples.allSatisfy({$0.point == point}) {
                    context.fillEllipse(in:CGRect(x:point.x-stroke.width/2,y:point.y-stroke.width/2,width:stroke.width,height:stroke.width))
                } else { context.addPath(InkPathBuilder.make(stroke:stroke).path); context.strokePath() }
            }
        }
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,"public.png" as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,image,nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

@MainActor
final class NoteLibraryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NoteLibraryWindowController()
    private let library: NoteLibrary
    private var refreshTimer: Timer?
    init(library: NoteLibrary = .shared) {
        self.library = library
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:680),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "노트 보관함"; window.minSize = NSSize(width:720,height:480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:NoteLibraryView(library:library))
        super.init(window:window); window.delegate = self; window.center()
        library.didOpenNote = { [weak self] in self?.close() }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowDidBecomeKey(_ notification: Notification) { if !library.busy { library.refresh() } }
    private func startMonitoring() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval:5,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true, self.window?.isMiniaturized == false,
                      !self.library.busy else { return }
                self.library.refresh(onlyIfChanged:true)
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer,forMode:.common)
    }
    private func stopMonitoring() { refreshTimer?.invalidate(); refreshTimer = nil }
    func windowWillClose(_ notification: Notification) { stopMonitoring() }
    override func close() { stopMonitoring(); super.close() }
    func present() {
        let alreadyKey = window?.isKeyWindow == true
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        startMonitoring()
        if alreadyKey { library.refresh() }
    }
}

struct NoteLibraryView: View {
    @ObservedObject var library: NoteLibrary
    @State private var newNoteHovered = false
    @State private var hoveredNote: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var naming: NoteLibrary.Card?
    @State private var creatingFolder = false
    @State private var name = ""
    @State private var deleting: NoteLibrary.Card?
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !library.busy else { return }
        library.busy = true
        Task { do { try await operation() } catch { library.errorMessage = error.localizedDescription }; library.busy = false }
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Label("노트 보관함",systemImage:"square.grid.2x2").font(.title.bold())
                Spacer()
                if library.loading { ProgressView().controlSize(.small) }
            }.padding(24)
            HStack(spacing:14) {
                if library.directory.path != library.root.path {
                    Button { library.directory = library.directory.deletingLastPathComponent(); library.refresh() } label: { Image(systemName:"chevron.left") }
                }
                LibraryScopePicker(favoritesOnly:$library.favoritesOnly)
                if library.directory.path != library.root.path {
                    Text(library.pathTitle).font(.headline).lineLimit(1)
                }
                Spacer()
                TextField("노트 검색",text:$library.query).textFieldStyle(.roundedBorder).frame(width:220)
                Picker("정렬",selection:$library.sort) { ForEach(NoteLibrary.Sort.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width:130)
            }.padding(.horizontal,24).padding(.bottom,20)
            Divider()
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:160,maximum:200),spacing:22)],spacing:28) {
                    ForEach(library.visibleFolders,id:\.path) { folder in
                        Button { library.directory = folder; library.refresh() } label: {
                            VStack(spacing:12) {
                                Image(systemName:"folder.fill").font(.system(size:86)).foregroundStyle(Color.blue.gradient).frame(height:190)
                                Text(folder.lastPathComponent).font(.headline).lineLimit(2).foregroundStyle(.primary)
                            }.frame(maxWidth:.infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    ForEach(library.visibleCards) { card in
                        VStack(spacing:10) {
                            ZStack(alignment:.topTrailing) {
                                Button { library.open(card) } label: {
                                    Group {
                                        if let data = card.preview, let image = NSImage(data:data) { Image(nsImage:image).resizable().scaledToFit() }
                                        else {
                                            ZStack { Color(nsColor:.controlBackgroundColor); Image(systemName:card.unreadable ? "exclamationmark.triangle" : "book.closed").font(.largeTitle).foregroundStyle(.secondary) }
                                        }
                                    }.frame(width:140,height:190).clipShape(RoundedRectangle(cornerRadius:7))
                                        // Hover must animate the frame, never cross-fade the decoded preview.
                                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                                        .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(Color.primary.opacity(0.12)))
                                        .shadow(color:.black.opacity(0.12),radius:4,y:2)
                                        .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(Color.accentColor.opacity(hoveredNote == card.id ? 0.9 : 0),lineWidth:2))
                                        .shadow(color:Color.accentColor.opacity(hoveredNote == card.id ? 0.38 : 0),radius:12,y:0)
                                }.buttonStyle(LibraryPreviewButtonStyle()).accessibilityLabel(card.name + " 열기")
                                Button { library.toggleFavorite(card.url) } label: {
                                    Image(systemName:library.favorites.contains(card.id) ? "star.fill" : "star")
                                        .foregroundStyle(library.favorites.contains(card.id) ? Color.orange : Color.secondary)
                                        .padding(7).background(.regularMaterial,in:Circle())
                                }.buttonStyle(FavoriteStarButtonStyle()).padding(5).accessibilityLabel("즐겨찾기 변경")
                            }
                            Text(card.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                            Text(card.unreadable ? "읽을 수 없는 노트" : card.modified.formatted(date:.abbreviated,time:.shortened))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth:.infinity)
                        .background {
                            RoundedRectangle(cornerRadius:12)
                                .fill(Color.accentColor.opacity(hoveredNote == card.id ? 0.08 : 0))
                                .padding(-8)
                        }
                        .contentShape(Rectangle())
                        .background(LibraryCardHover { inside in
                            if inside { hoveredNote = card.id }
                            else if hoveredNote == card.id { hoveredNote = nil }
                        })
                        .contextMenu {
                            Button("열기") { library.open(card) }
                            Button("이름 변경…") { naming = card; name = card.name }
                            Button("복제") { run { _ = try await library.duplicate(card) } }
                            Menu("폴더로 이동") {
                                ForEach([library.root] + library.folders,id:\.path) { folder in
                                    Button(folder.path == library.root.path ? "모든 노트" : folder.path.replacingOccurrences(of:library.root.path+"/",with:"")) {
                                        run { try await library.move(card,to:folder.appendingPathComponent(card.url.lastPathComponent)) }
                                    }.disabled(folder.path == card.url.deletingLastPathComponent().path)
                                }
                            }
                            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([card.url]) }
                            Divider()
                            Button("휴지통으로 이동…",role:.destructive) { deleting = card }
                        }
                    }
                    Menu {
                        Button("새 노트") { run { try await library.createNote() } }
                        Button("학생 신규 상담 · A4 세로") { run { try await library.createNote(template:.studentConsultation) } }
                        Divider()
                        Button("새 폴더") { name = ""; creatingFolder = true }
                    } label: {
                        VStack(spacing:10) {
                            RoundedRectangle(cornerRadius:7)
                                .fill(Color.accentColor.opacity(newNoteHovered ? 0.16 : 0.05))
                                .overlay {
                                    RoundedRectangle(cornerRadius:7)
                                        .strokeBorder(Color.accentColor.opacity(newNoteHovered ? 0.85 : 0.4),
                                                      style:StrokeStyle(lineWidth:2,dash:[7,5]))
                                }
                                .overlay { Image(systemName:"plus").font(.system(size:44,weight:.light)).foregroundStyle(Color.accentColor) }
                                .frame(width:140,height:190)
                            Text("신규").font(.headline).foregroundStyle(.primary)
                            Text("클릭하여 만들기").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity).contentShape(Rectangle())
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .onHover { newNoteHovered = $0 }
                        .help("새 노트 · 학생 상담 양식 · 새 폴더")
                        .accessibilityLabel("신규 문서 또는 폴더 만들기")
                        .accessibilityIdentifier("library-new-note-card")
                }.padding(24)
                if library.visibleCards.isEmpty && library.visibleFolders.isEmpty {
                    ContentUnavailableView("표시할 노트가 없습니다",systemImage:"books.vertical",description:Text("새 노트를 만들거나 검색 조건을 바꿔 보세요."))
                }
            }
            Divider()
            HStack { Text("\(library.visibleCards.count)개 노트"); Spacer(); Text("클릭하여 열기 · 우클릭하여 관리") }
                .font(.caption).foregroundStyle(.secondary).padding(12)
        .alert("보관함 오류",isPresented:Binding(get:{library.errorMessage != nil},set:{if !$0 {library.errorMessage = nil}})) {
            Button("확인") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        }
        .background(Color(nsColor:.windowBackgroundColor)).disabled(library.busy)
        .overlay { if library.busy { ProgressView().padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) } }
        .alert(deleting != nil ? "노트를 휴지통으로 이동할까요?" : (creatingFolder ? "새 폴더" : "이름 변경"),
               isPresented:Binding(get:{creatingFolder || naming != nil || deleting != nil},set:{if !$0 {creatingFolder = false; naming = nil; deleting = nil}})) {
            if let card = deleting {
                Button("취소",role:.cancel) { deleting = nil }
                Button("휴지통으로 이동",role:.destructive) { deleting = nil; run { try await library.delete(card) } }
            } else {
                TextField(creatingFolder ? "폴더 이름" : "노트 이름",text:$name)
                Button("취소",role:.cancel) { creatingFolder = false; naming = nil }
                Button(creatingFolder ? "만들기" : "변경") {
                    let create = creatingFolder, card = naming, value = name
                    creatingFolder = false; naming = nil
                    run {
                        if create { try library.createFolder(name:value) }
                        else if let card { try await library.rename(card,to:value) }
                    }
                }
            }
        } message: { if let card = deleting { Text(card.name) } }

    }
}

/// Use the same system tab-role segmented control as native preference tabs.
/// AppKit owns lens tracking, optical effects and accessibility preferences.
struct LibraryScopePicker: NSViewRepresentable {
    @Binding var favoritesOnly: Bool
    func makeCoordinator() -> Coordinator { Coordinator(favoritesOnly:$favoritesOnly) }
    func makeNSView(context:Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels:["모든 노트","즐겨찾기"],trackingMode:.selectOne,
                                         target:context.coordinator,action:#selector(Coordinator.changed(_:)))
        control.segmentStyle = .automatic
        control.segmentDistribution = .fillEqually
        control.font = .systemFont(ofSize:14,weight:.semibold)
        if #available(macOS 26.0, *) {
            control.prefersCompactControlSizeMetrics = false
            control.controlSize = .extraLarge
            control.borderShape = .capsule
        } else {
            control.controlSize = .large
        }
        if #available(macOS 27.0, *) { control.role = .tabs }
        control.setAccessibilityLabel("노트 보기")
        control.setToolTip("모든 노트 보기",forSegment:0)
        control.setToolTip("즐겨찾는 노트 보기",forSegment:1)
        return control
    }
    func updateNSView(_ control:NSSegmentedControl,context:Context) {
        context.coordinator.favoritesOnly = $favoritesOnly
        let selected = favoritesOnly ? 1 : 0
        if control.selectedSegment != selected { control.selectedSegment = selected }
        control.isEnabled = context.environment.isEnabled
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSSegmentedControl,context:Context) -> CGSize? {
        CGSize(width:276,height:max(42,nsView.intrinsicContentSize.height))
    }
    @MainActor final class Coordinator: NSObject {
        var favoritesOnly: Binding<Bool>
        init(favoritesOnly:Binding<Bool>) { self.favoritesOnly = favoritesOnly }
        @objc func changed(_ sender:NSSegmentedControl) {
            guard (0...1).contains(sender.selectedSegment) else { return }
            favoritesOnly.wrappedValue = sender.selectedSegment == 1
        }
    }
}

/// Track the entire card even when the library is not the keyboard-active window.
private struct LibraryCardHover: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context:Context) -> HoverView { HoverView(changed:changed) }
    func updateNSView(_ view:HoverView,context:Context) { view.changed = changed }
    final class HoverView: NSView {
        var changed: (Bool) -> Void
        private var area: NSTrackingArea?
        private var inside = false
        init(changed:@escaping (Bool) -> Void) {
            self.changed = changed; super.init(frame:.zero)
            identifier = NSUserInterfaceItemIdentifier("library-card-hover")
        }
        required init?(coder:NSCoder) { fatalError("init(coder:) unavailable") }
        override func hitTest(_ point:NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.mouseMoved,.activeAlways,.inVisibleRect],owner:self)
            addTrackingArea(next); area = next
        }
        private func report(_ value:Bool) {
            guard inside != value else { return }
            inside = value; changed(value)
        }
        override func mouseEntered(with event:NSEvent) { report(true) }
        override func mouseMoved(with event:NSEvent) { report(true) }
        override func mouseExited(with event:NSEvent) { report(false) }
    }
}

/// Keep the note artwork at full brightness through pointer and press changes.
private struct LibraryPreviewButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct FavoriteStarButtonStyle: ButtonStyle {
    func makeBody(configuration:Configuration) -> some View { Star(configuration:configuration) }
    private struct Star: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96 : (hovering ? 1.12 : 1)))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .spring(response:0.24,dampingFraction:0.75),value:hovering)
                .animation(reduceMotion ? nil : .easeOut(duration:0.1),value:configuration.isPressed)
        }
    }
}
