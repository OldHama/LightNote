import Foundation
import CryptoKit
import Darwin

public struct RecoveryDelta: Codable, Sendable {
    public struct Put: Codable, Sendable {
        public var index: Int
        public var stroke: InkStroke
        public init(index: Int, stroke: InkStroke) { self.index = index; self.stroke = stroke }
    }
    public var puts: [Put] = []
    public var removed: [UUID] = []
    public var paper: PaperStyle?
    public init(puts: [Put] = [], removed: [UUID] = [], paper: PaperStyle? = nil) {
        self.puts = puts; self.removed = removed; self.paper = paper
    }
    public func apply(to note: inout NoteFile) {
        let ids = Set(removed + puts.map { $0.stroke.id })
        note.strokes.removeAll { ids.contains($0.id) }
        for item in puts.sorted(by: { $0.index < $1.index }) {
            note.strokes.insert(item.stroke, at: max(0, min(item.index, note.strokes.count)))
        }
        if let paper { note.paperStyle = paper }
    }
}

/// Durable per-edit records; a process-held flock prevents recovery of a live session.
/// Only completed, checksummed records are replayed. The original is never overwritten.
public final class RecoveryJournal {
    struct Manifest: Codable { var source: URL; var baseDigest: Data }
    public struct Report: Sendable { public var recovered: [URL] = []; public var unreadable: [URL] = []; public var sources: [URL: URL] = [:] }
    public let directory: URL
    private let lease: FileHandle
    private let log: FileHandle
    private var closed = false
    private var manifest: Manifest
    public static func safeName(_ input: String) -> String {
        var name = input
        for marker in [" (복구 ", " (충돌 "] { if let range = name.range(of: marker) { name = String(name[..<range.lowerBound]) } }
        if name.hasPrefix("노트-"), UUID(uuidString: String(name.dropFirst(3))) != nil { name = "새 노트" }
        var safe = ""
        for character in name {
            let next = String(character)
            if safe.utf8.count + next.utf8.count > 120 { break }
            safe += next
        }
        return safe.isEmpty ? "노트" : safe
    }
    public static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }
    public init(root: URL, source: URL, baseData: Data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root.appendingPathComponent(UUID().uuidString + ".journal", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("lease")
        FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        lease = try FileHandle(forUpdating: lockURL)
        guard flock(lease.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
        try Self.durableWrite(baseData, to: directory.appendingPathComponent("base.lightnote"))
        manifest = Manifest(source: source, baseDigest: Self.digest(baseData))
        try Self.durableWrite(JSONEncoder().encode(manifest), to: directory.appendingPathComponent("manifest.json"))
        let logURL = directory.appendingPathComponent("edits")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forUpdating: logURL)
    }
    public func retarget(to source: URL) throws {
        guard manifest.source != source else { return }
        var updated = manifest
        updated.source = source
        try Self.durableWrite(JSONEncoder().encode(updated), to: directory.appendingPathComponent("manifest.json"))
        manifest = updated
    }
    public func append(_ delta: RecoveryDelta) throws {
        let payload = try JSONEncoder().encode(delta)
        var length = UInt64(payload.count).littleEndian
        var record = withUnsafeBytes(of: &length) { Data($0) }
        record.append(payload); record.append(Self.digest(payload))
        let position = try log.seekToEnd()
        do { try log.write(contentsOf: record); try log.synchronize() }
        catch {
            try? log.truncate(atOffset: position)
            throw error
        }
    }
    public func discard() throws {
        guard !closed else { return }
        try log.close()
        // Hold the lease until the directory is gone, including on cleanup failure.
        try FileManager.default.removeItem(at: directory)
        try lease.close(); closed = true
    }
    deinit { try? log.close(); try? lease.close() }

    public static func recoverPending(root: URL, destination: URL) throws -> Report {
        var report = Report()
        guard FileManager.default.fileExists(atPath: root.path) else { return report }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]).sorted(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        })
            where folder.pathExtension == "journal" {
            guard let lock = try? FileHandle(forUpdating: folder.appendingPathComponent("lease")) else {
                report.unreadable.append(folder); continue
            }
            defer { try? lock.close() }
            guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
                let base = try Data(contentsOf: folder.appendingPathComponent("base.lightnote"))
                guard digest(base) == manifest.baseDigest else { throw NoteError.invalidData }
                var note = try NoteFile.decode(base)
                let bytes = try Data(contentsOf: folder.appendingPathComponent("edits"))
                var cursor = 0, count = 0
                while cursor < bytes.count {
                    guard bytes.count-cursor >= 8 else { break }
                    let size = bytes[cursor..<cursor+8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset*8) }
                    guard size <= UInt64(bytes.count-cursor-8), bytes.count-cursor-8-Int(size) >= 32 else { break }
                    let start = cursor+8, end = start+Int(size)
                    let payload = bytes.subdata(in: start..<end)
                    guard digest(payload) == bytes.subdata(in: end..<end+32) else { break }
                    guard let delta = try? JSONDecoder().decode(RecoveryDelta.self, from: payload),
                          (try? NoteFile(strokes: delta.puts.map { $0.stroke }).validate()) != nil else { break }
                    delta.apply(to: &note)
                    count += 1; cursor = end+32
                }
                try note.validate()
                if cursor != bytes.count { report.unreadable.append(folder) }
                let disk = (try? Data(contentsOf: manifest.source)).flatMap { try? NoteFile.decode($0) }
                if count > 0 || disk == nil, disk != note {
                    // A deterministic name makes recovery retry safe if killed after creating the copy.
                    let name = safeName(manifest.source.deletingPathExtension().lastPathComponent)
                    var recovered = destination.appendingPathComponent("\(name) (복구 \(folder.deletingPathExtension().lastPathComponent)).lightnote")
                    if FileManager.default.fileExists(atPath: recovered.path),
                       (try? NoteFile.decode(Data(contentsOf: recovered))) != note {
                        // A previous recovery may have been edited before cleanup failed.
                        // Never replace that independent copy on a later recovery attempt.
                        recovered = destination.appendingPathComponent("\(name) (복구 \(UUID().uuidString)).lightnote")
                    }
                    if !FileManager.default.fileExists(atPath: recovered.path) { try durableWrite(note.encoded(), to: recovered) }
                    report.recovered.append(recovered)
                    report.sources[recovered] = manifest.source
                }
                // Preserve damaged logs for manual inspection; never silently delete them.
                if cursor != bytes.count {
                    let archived = folder.deletingPathExtension().appendingPathExtension("recovered")
                    try FileManager.default.moveItem(at: folder, to: archived)
                } else { try FileManager.default.removeItem(at: folder) }
            } catch { report.unreadable.append(folder) }
        }
        return report
    }
}
