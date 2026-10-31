import XCTest
@testable import LightNoteCore

final class FreeArrowTests: XCTestCase {
    func arrow(_ points: [CGPoint]) -> InkStroke {
        var result = InkStroke(width: 2, samples: points.enumerated().map { InkSample(x:$0.element.x,y:$0.element.y,time:Double($0.offset)) })
        result.tool = "freeArrow"
        return result
    }
    func testCurvedShaftAndHeadAreBothInGeometry() throws {
        let stroke = arrow([.zero,CGPoint(x:10,y:-30),CGPoint(x:40,y:-40),CGPoint(x:70,y:-10),CGPoint(x:80,y:30)])
        let geometry = InkPathBuilder.make(stroke:stroke)
        var lines = 0
        geometry.path.applyWithBlock { element in
            if element.pointee.type == .addLineToPoint { lines += 1 }
        }
        let body = InkPathBuilder.make(samples:stroke.samples)
        XCTAssertGreaterThanOrEqual(lines,stroke.samples.count)
        XCTAssertEqual(Array(geometry.points.prefix(body.points.count)),body.points)
        XCTAssertEqual(geometry.points.count,body.points.count+3)
        XCTAssertLessThan(geometry.path.boundingBoxOfPath.minY,-30)
        XCTAssertEqual(stroke.freeArrowHead[1],stroke.samples.last!.point)
        for point in stroke.freeArrowHead { XCTAssertTrue(stroke.bounds.contains(point)) }
        XCTAssertEqual(try NoteFile.decode(NoteFile(strokes:[stroke]).encoded()).strokes,[stroke])
        let copy = stroke.copied(offset:CGSize(width:20,height:30))
        XCTAssertNotEqual(copy.id,stroke.id)
        for (a,b) in zip(stroke.freeArrowHead,copy.freeArrowHead) { XCTAssertEqual(a.x+20,b.x,accuracy:1e-8); XCTAssertEqual(a.y+30,b.y,accuracy:1e-8) }
    }
    func testHeadFollowsTailAndIgnoresDuplicateReleaseSamples() {
        for tip in [CGPoint(x:100,y:0),CGPoint(x:-100,y:0),CGPoint(x:0,y:100),CGPoint(x:0,y:-100)] {
            let stroke = arrow([.zero,tip])
            XCTAssertEqual(stroke.freeArrowHead.count,3)
            for wing in [stroke.freeArrowHead[0],stroke.freeArrowHead[2]] {
                XCTAssertLessThan((wing.x-tip.x)*tip.x+(wing.y-tip.y)*tip.y,0)
            }
            let duplicate = arrow([.zero,tip,tip,tip])
            XCTAssertEqual(duplicate.freeArrowHead,stroke.freeArrowHead)
        }
    }
    func testDotShortStrokeAndReturningTailAreFinite() {
        XCTAssertTrue(arrow([.zero,.zero]).freeArrowHead.isEmpty)
        let tiny = arrow([.zero,CGPoint(x:2,y:0)])
        XCTAssertEqual(tiny.freeArrowHead.count,3)
        XCTAssertLessThan(hypot(tiny.freeArrowHead[0].x-2,tiny.freeArrowHead[0].y),2)
        let returning = arrow([.zero,CGPoint(x:3,y:0),.zero])
        XCTAssertEqual(returning.freeArrowHead.count,3)
        XCTAssertTrue(returning.freeArrowHead.allSatisfy{$0.x.isFinite && $0.y.isFinite})
    }
    func testHeadParticipatesInEraserHitTesting() {
        let stroke = arrow([.zero,CGPoint(x:0,y:-100)])
        let head = stroke.freeArrowHead
        let point = CGPoint(x:(head[0].x+head[1].x)/2,y:(head[0].y+head[1].y)/2)
        XCTAssertTrue(stroke.intersectsEraser(from:point,to:point,radius:0.1))
        XCTAssertFalse(stroke.intersectsEraser(from:CGPoint(x:100,y:100),to:CGPoint(x:100,y:100),radius:1))
    }
}
