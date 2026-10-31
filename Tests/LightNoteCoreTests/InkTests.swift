import XCTest
@testable import LightNoteCore

final class InkTests: XCTestCase {
    func testVectorRoundtripPreservesEverySample() throws {
        let points = (0..<10000).map { i in
            InkSample(x: Double(i) / 20, y: sin(Double(i)), time: Double(i) / 240,
                      pressure: Double(i % 101) / 100)
        }
        let note = NoteFile(strokes: [InkStroke(color: .blue, width: 0.5, samples: points)])
        XCTAssertEqual(try NoteFile.decode(note.encoded()), note)
    }
    func testPaperStyleRoundtripAndLegacyDefault() throws {
        var note = NoteFile()
        note.paperStyle = .grid
        XCTAssertEqual(try NoteFile.decode(note.encoded()).paperStyle, .grid)
        let legacy = Data("{\"version\":1,\"pageWidth\":794,\"pageHeight\":1123,\"strokes\":[]}".utf8)
        XCTAssertEqual(try NoteFile.decode(legacy).paperStyle, .blank)
    }

    func testSweptEraserCrossingAndNearMiss() {
        let stroke = InkStroke(width: 2, samples: [
            InkSample(x: 10, y: 0, time: 0), InkSample(x: 10, y: 100, time: 1)
        ])
        XCTAssertTrue(stroke.intersectsEraser(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50), radius: 6))
        XCTAssertFalse(stroke.intersectsEraser(from: CGPoint(x: 30, y: 0), to: CGPoint(x: 30, y: 100), radius: 6))
        XCTAssertTrue(stroke.intersectsEraser(from: CGPoint(x: 16, y: 50), to: CGPoint(x: 16, y: 50), radius: 6))
    }

    func testLightSmoothingDensityEndpointsAndRawSamples() throws {
        let samples = [InkSample(x: 0, y: 0, time: 0), InkSample(x: 10, y: 0, time: 1),
                       InkSample(x: 10, y: 10, time: 2)]
        let geometry = InkPathBuilder.make(samples: samples)
        XCTAssertEqual(geometry.points.first, samples.first!.point)
        XCTAssertEqual(geometry.points.last, samples.last!.point)
        XCTAssertGreaterThan(geometry.points.count, samples.count)
        XCTAssertTrue(geometry.points.contains(CGPoint(x: 10, y: 0)), "Input landmarks must remain exact")
        for (a, b) in zip(geometry.points, geometry.points.dropFirst()) {
            XCTAssertLessThanOrEqual(hypot(b.x-a.x, b.y-a.y), 0.751)
        }
        for p in geometry.points {
            XCTAssertGreaterThanOrEqual(p.x, -1e-9); XCTAssertLessThanOrEqual(p.x, 10 + 1e-9)
            XCTAssertGreaterThanOrEqual(p.y, -1e-9); XCTAssertLessThanOrEqual(p.y, 10 + 1e-9)
            XCTAssertLessThanOrEqual(min(abs(p.y), abs(10-p.x)), 1.25)
        }
        let note = NoteFile(strokes: [InkStroke(samples: samples)])
        XCTAssertEqual(try NoteFile.decode(note.encoded()).strokes[0].samples, samples)
        let duplicate = InkPathBuilder.make(samples: [samples[0], samples[0]])
        XCTAssertEqual(duplicate.points, [.zero])
    }

    func testSparseCircleInterpolationReducesPolygonFacets() {
        let radius = 200.0
        let samples = (0...16).map { i in
            let angle = Double(i) * 2 * .pi / 16
            return InkSample(x: 250 + radius * cos(angle), y: 250 + radius * sin(angle), time: Double(i)/60)
        }
        let geometry = InkPathBuilder.make(samples: samples)
        let errors = geometry.points.map { abs(hypot($0.x-250, $0.y-250)-radius) }
        let polygonMidpointError = radius * (1-cos(Double.pi/16))
        let meanError = errors.reduce(0, +) / Double(errors.count)
        XCTAssertLessThan(meanError, polygonMidpointError * 0.45)
        for sample in samples { XCTAssertTrue(geometry.points.contains(sample.point)) }
        XCTAssertEqual(geometry.points.first, samples.first!.point)
        XCTAssertEqual(geometry.points.last, samples.last!.point)
        for (a, b) in zip(geometry.points, geometry.points.dropFirst()) {
            XCTAssertLessThanOrEqual(hypot(b.x-a.x, b.y-a.y), 0.501)
        }
    }

    func testEraserCircleTouchesVisibleStrokeEdge() {
        let stroke = InkStroke(width: 2, samples: [InkSample(x: 100, y: 100, time: 0)])
        for scale: CGFloat in [0.25, 0.5, 1, 2, 4] {
            let screenRadius: CGFloat = 6 * scale
            let edge = CGPoint(x: (100 * scale + screenRadius + scale) / scale, y: 100)
            XCTAssertTrue(stroke.intersectsEraser(from: edge, to: edge, radius: 6))
            let outside = CGPoint(x: edge.x + 0.01 / scale, y: 100)
            XCTAssertFalse(stroke.intersectsEraser(from: outside, to: outside, radius: 6))
        }
    }

    func testLaserHoldAndReleaseFadeTiming() {
        XCTAssertEqual(LaserTiming.opacity(releasedAt: nil, now: 100000), 1)
        XCTAssertEqual(LaserTiming.opacity(releasedAt: 10, now: 10), 1)
        XCTAssertEqual(LaserTiming.opacity(releasedAt: 10, now: 11), 1)
        XCTAssertEqual(LaserTiming.opacity(releasedAt: 10, now: 12), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LaserTiming.opacity(releasedAt: 10, now: 13), 0)
        XCTAssertEqual(LaserTiming.opacity(releasedAt: 10, now: 20), 0)
    }

    func testDotBoundsAreNotEmpty() {
        let dot = InkStroke(width: 0.5, samples: [InkSample(x: 50, y: 60, time: 0)])
        XCTAssertFalse(dot.bounds.isEmpty)
        XCTAssertTrue(dot.bounds.contains(CGPoint(x: 50, y: 60)))
    }
    func testUnknownVersionAndMalformedDataRejected() throws {
        let future = Data("{\"version\":99,\"pageWidth\":794,\"pageHeight\":1123,\"strokes\":[]}".utf8)
        XCTAssertThrowsError(try NoteFile.decode(future))
        XCTAssertThrowsError(try NoteFile.decode(Data("partial".utf8)))
    }
    func testUnsafeRenderingValuesRejected() {
        var note = NoteFile(strokes: [InkStroke(samples: [InkSample(x: 10, y: 10, time: 0)])])
        note.strokes[0].width = -1
        XCTAssertThrowsError(try note.validate())
        note.strokes[0].width = 1
        note.strokes[0].samples[0].x = .infinity
        XCTAssertThrowsError(try note.validate())
        note.strokes[0].samples[0].x = 10
        note.strokes[0].samples[0].pressure = 2
        XCTAssertThrowsError(try note.validate())
    }
    func testDuplicateIDsRejected() {
        let stroke = InkStroke(samples: [InkSample(x: 0, y: 0, time: 0)])
        XCTAssertThrowsError(try NoteFile(strokes: [stroke, stroke]).validate())
    }
}
