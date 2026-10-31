import XCTest
@testable import LightNoteCore

final class RecoveryTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func stroke(_ x: Double) -> InkStroke { InkStroke(samples: [InkSample(x: x, y: 20, time: x)]) }
    func testDeltaReplayPreservesOrderMovementDeletionAndPaper() throws {
        let a = stroke(1), b = stroke(2), c = stroke(3)
        var note = NoteFile(strokes: [a,b,c])
        let moved = b.copied(offset: CGSize(width: 5, height: 6))
        RecoveryDelta(puts: [.init(index: 1, stroke: moved)], removed: [b.id], paper: .blank).apply(to: &note)
        XCTAssertEqual(note.strokes, [a,moved,c]); XCTAssertEqual(note.paperStyle,.blank)
        RecoveryDelta(removed: [a.id,c.id]).apply(to: &note)
        XCTAssertEqual(note.strokes,[moved])
        RecoveryDelta(puts: [.init(index: 0,stroke:a),.init(index:2,stroke:c)]).apply(to:&note)
        XCTAssertEqual(note.strokes,[a,moved,c])
    }
    func testLiveJournalIsSkippedAndReleasedJournalRecoversWithoutOverwritingSource() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.lightnote"), base = NoteFile(strokes:[stroke(1)])
        let baseData = try base.encoded(); try baseData.write(to: source)
        var journal: RecoveryJournal? = try RecoveryJournal(root:root,source:source,baseData:baseData)
        let b = stroke(2); try journal!.append(.init(puts:[.init(index:1,stroke:b)]))
        XCTAssertTrue(try RecoveryJournal.recoverPending(root: root,destination:root).recovered.isEmpty)
        journal = nil
        let report = try RecoveryJournal.recoverPending(root:root,destination:root)
        XCTAssertEqual(report.recovered.count,1)
        XCTAssertEqual(try NoteFile.decode(Data(contentsOf:report.recovered[0])).strokes,base.strokes+[b])
        XCTAssertEqual(try Data(contentsOf:source),baseData)
        XCTAssertTrue(try RecoveryJournal.recoverPending(root:root,destination:root).recovered.isEmpty)
    }
    func testTruncatedAndBadChecksumTailRecoversLastCompleteEdit() throws {
        for corrupt in [false,true] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
            let source=root.appendingPathComponent("source.lightnote"), base=NoteFile()
            try base.encoded().write(to:source)
            var journal:RecoveryJournal?=try RecoveryJournal(root:root,source:source,baseData:base.encoded())
            let a=stroke(1), b=stroke(2)
            try journal!.append(.init(puts:[.init(index:0,stroke:a)]))
            let log=journal!.directory.appendingPathComponent("edits")
            let complete=try Data(contentsOf:log)
            try journal!.append(.init(puts:[.init(index:1,stroke:b)]))
            var damaged=try Data(contentsOf:log)
            journal=nil
            if corrupt { damaged[damaged.count-1] ^= 0xff }
            else { damaged=Data(damaged.prefix(complete.count+9)) }
            try damaged.write(to:log)
            let result=try RecoveryJournal.recoverPending(root:root,destination:root)
            XCTAssertEqual(result.recovered.count,1); XCTAssertEqual(result.unreadable.count,1)
            XCTAssertEqual(try NoteFile.decode(Data(contentsOf:result.recovered[0])).strokes,[a])
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).contains{$0.pathExtension=="recovered"})
        }
    }
    func testAlreadySavedEditsDoNotCreateDuplicateRecoveryNote() throws {
        let root=try fixture(); defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.lightnote"), base=NoteFile(), a=stroke(1)
        var journal:RecoveryJournal?=try RecoveryJournal(root:root,source:source,baseData:base.encoded())
        try journal!.append(.init(puts:[.init(index:0,stroke:a)]))
        try NoteFile(strokes:[a]).encoded().write(to:source)
        journal=nil
        XCTAssertTrue(try RecoveryJournal.recoverPending(root:root,destination:root).recovered.isEmpty)
    }
    func testCorruptOrMissingOriginalRecoversEvenWithoutNewEdits() throws {
        for missing in [false,true] {
            let root=try fixture(); defer{try? FileManager.default.removeItem(at:root)}
            let source=root.appendingPathComponent("source.lightnote"), base=NoteFile(strokes:[stroke(1)])
            var journal:RecoveryJournal?=try RecoveryJournal(root:root,source:source,baseData:base.encoded())
            if !missing { try Data("bad original".utf8).write(to:source) }
            XCTAssertNotNil(journal); journal=nil
            let report=try RecoveryJournal.recoverPending(root:root,destination:root)
            XCTAssertEqual(report.recovered.count,1)
            XCTAssertEqual(try NoteFile.decode(Data(contentsOf:report.recovered[0])),base)
            if !missing { XCTAssertEqual(try Data(contentsOf:source),Data("bad original".utf8)) }
        }
    }
    func testCorruptRecoveryBaseRetainsEntireJournal() throws {
        let root=try fixture(); defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.lightnote"), base=NoteFile()
        var journal:RecoveryJournal?=try RecoveryJournal(root:root,source:source,baseData:base.encoded())
        try journal!.append(.init(puts:[.init(index:0,stroke:stroke(1))]))
        let directory=journal!.directory; journal=nil
        try Data("damaged base".utf8).write(to:directory.appendingPathComponent("base.lightnote"))
        let report=try RecoveryJournal.recoverPending(root:root,destination:root)
        XCTAssertTrue(report.recovered.isEmpty); XCTAssertEqual(report.unreadable.map { $0.resolvingSymlinksInPath().path },[directory.resolvingSymlinksInPath().path])
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("edits").path))
    }
    func testRetargetedSavedConflictCopyDoesNotCreateDuplicate() throws {
        let root=try fixture(); defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.lightnote"), fork=root.appendingPathComponent("fork.lightnote")
        var journal:RecoveryJournal?=try RecoveryJournal(root:root,source:source,baseData:NoteFile().encoded())
        let a=stroke(1)
        try journal!.append(.init(puts:[.init(index:0,stroke:a)]))
        try NoteFile(strokes:[a]).encoded().write(to:fork)
        try journal!.retarget(to:fork); journal=nil
        XCTAssertTrue(try RecoveryJournal.recoverPending(root:root,destination:root).recovered.isEmpty)
    }
    func testExistingEditedRecoveryCopyIsNeverOverwritten() throws {
        let root=try fixture(); defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.lightnote"), a=stroke(1)
        var journal:RecoveryJournal?=try RecoveryJournal(root:root,source:source,baseData:NoteFile().encoded())
        try journal!.append(.init(puts:[.init(index:0,stroke:a)]))
        let directory=journal!.directory
        let candidate=root.appendingPathComponent("source (복구 \(directory.deletingPathExtension().lastPathComponent)).lightnote")
        let modified=NoteFile(strokes:[stroke(99)])
        try modified.encoded().write(to:candidate); journal=nil
        let report=try RecoveryJournal.recoverPending(root:root,destination:root)
        XCTAssertEqual(report.recovered.count,1); XCTAssertNotEqual(report.recovered[0],candidate)
        XCTAssertEqual(try NoteFile.decode(Data(contentsOf:candidate)),modified)
        XCTAssertEqual(try NoteFile.decode(Data(contentsOf:report.recovered[0])).strokes,[a])
    }

    func testRecoveryNamesStayWithinFilenameByteBudget() {
        XCTAssertLessThanOrEqual(RecoveryJournal.safeName(String(repeating:"👨‍👩‍👧‍👦",count:50)).utf8.count,120)
        XCTAssertEqual(RecoveryJournal.safeName("수업 (충돌 ABC) (복구 DEF)"),"수업")
        XCTAssertEqual(RecoveryJournal.safeName("노트-"+UUID().uuidString),"새 노트")
    }

}
