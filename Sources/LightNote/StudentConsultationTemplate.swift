import AppKit

/// A4 at 72 points per inch; the background is a locked, self-contained PNG.
@MainActor
enum StudentConsultationTemplate {
    static let width = 210.0 / 25.4 * 72
    static let height = 297.0 / 25.4 * 72
    static func makeNote() throws -> NoteFile {
        let data = try renderPNG()
        var background = InkStroke(samples:[InkSample(x:0,y:0,time:0),InkSample(x:width,y:height,time:0)])
        background.tool = "image"; background.imagePNG = data; background.locked = true
        var note = NoteFile(strokes:[background])
        note.pageWidth = width; note.pageHeight = height; note.paperStyle = .blank
        try note.validate()
        return note
    }
    static func renderPNG() throws -> Data {
        let scale = 3.0
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(ceil(width*scale)),pixelsHigh:Int(ceil(height*scale)),
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let graphics = NSGraphicsContext(bitmapImageRep:bitmap) else { throw CocoaError(.fileWriteUnknown) }
        let context = graphics.cgContext
        context.translateBy(x:0,y:CGFloat(bitmap.pixelsHigh)); context.scaleBy(x:scale,y:-scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let navy = NSColor(srgbRed:0.10,green:0.19,blue:0.31,alpha:1)
        let muted = NSColor(srgbRed:0.36,green:0.41,blue:0.47,alpha:1)
        let border = NSColor(srgbRed:0.72,green:0.76,blue:0.81,alpha:1)
        let tint = NSColor(srgbRed:0.93,green:0.95,blue:0.97,alpha:1)
        let left = 28.0, right = width-28, content = width-56
        func fill(_ rect: CGRect, _ color: NSColor) { context.setFillColor(color.cgColor); context.fill(rect) }
        func line(_ a: CGPoint, _ b: CGPoint, color: NSColor = border, width: Double = 0.65) {
            context.setStrokeColor(color.cgColor); context.setLineWidth(width)
            context.beginPath(); context.move(to:a); context.addLine(to:b); context.strokePath()
        }
        func box(_ rect: CGRect) { context.setStrokeColor(border.cgColor); context.setLineWidth(0.65); context.stroke(rect) }
        func text(_ value: String, x: Double, y: Double, size: Double = 9, bold: Bool = false, color: NSColor = navy) {
            (value as NSString).draw(at:CGPoint(x:x,y:y),withAttributes:[
                .font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold : .regular),.foregroundColor:color])
        }
        func section(_ number: String, _ title: String, y: Double) {
            fill(CGRect(x:left,y:y,width:content,height:23),tint)
            fill(CGRect(x:left,y:y,width:3,height:23),navy)
            text(number + "   " + title,x:left+11,y:y+5,size:10,bold:true)
        }
        func field(_ label: String, x: Double, y: Double, width: Double, height: Double = 35) {
            box(CGRect(x:x,y:y,width:width,height:height))
            text(label,x:x+9,y:y+6,size:8,color:muted)
        }
        func writingArea(_ label: String, y: Double, height: Double) {
            box(CGRect(x:left,y:y,width:content,height:height))
            text(label,x:left+10,y:y+7,size:8.5,bold:true,color:muted)
            var row = y+34
            while row < y+height-5 {
                line(CGPoint(x:left+10,y:row),CGPoint(x:right-10,y:row),color:NSColor(srgbRed:0.88,green:0.90,blue:0.92,alpha:1),width:0.4)
                row += 19
            }
        }
        func check(_ label: String, x: Double, y: Double) {
            box(CGRect(x:x,y:y+2,width:6,height:6)); text(label,x:x+11,y:y,size:8.5)
        }
        fill(CGRect(x:0,y:0,width:width,height:height),.white)
        text("신규 학생 상담 기록지",x:left,y:27,size:22,bold:true)
        text("학생의 관심과 목표를 이해하고, 함께 수업 계획을 세웁니다.",x:left,y:59,size:9,color:muted)
        text("상담일  ______ 년  ____ 월  ____ 일     상담자  __________________",x:left,y:80,size:9)
        line(CGPoint(x:left,y:103),CGPoint(x:right,y:103),color:navy,width:1.4)

        section("01","학생 · 보호자 정보",y:116)
        let half = content/2
        field("학생 이름",x:left,y:139,width:half)
        field("학교 · 학년",x:left+half,y:139,width:half)
        field("보호자 이름 · 학생과의 관계",x:left,y:174,width:half)
        field("보호자 연락처",x:left+half,y:174,width:half)
        field("희망 수업 요일 · 시간",x:left,y:209,width:half)
        field("상담 경로 (소개 / 검색 / 기타)",x:left+half,y:209,width:half)

        section("02","학습 경험 · 관심",y:256)
        box(CGRect(x:left,y:279,width:content,height:81))
        text("코딩 경험",x:left+10,y:289,size:8.5,bold:true,color:muted)
        check("없음",x:left+75,y:289); check("스크래치·엔트리",x:left+130,y:289)
        check("파이썬",x:left+245,y:289); check("기타 __________",x:left+320,y:289)
        text("관심 분야",x:left+10,y:313,size:8.5,bold:true,color:muted)
        check("게임",x:left+75,y:313); check("앱·웹",x:left+130,y:313)
        check("인공지능",x:left+198,y:313); check("로봇",x:left+278,y:313); check("알고리즘",x:left+340,y:313)
        text("현재 학습 수준 · 사용해 본 도구",x:left+10,y:337,size:8,color:muted)
        line(CGPoint(x:left+155,y:351),CGPoint(x:right-10,y:351))

        section("03","상담 내용",y:372)
        writingArea("학생의 관심 · 강점 · 학습 성향",y:395,height:61)
        writingArea("학생 · 보호자가 기대하는 점 / 학습 목표",y:456,height:61)
        writingArea("어려운 점 · 지원이 필요한 부분",y:517,height:61)

        section("04","수업 제안 · 다음 단계",y:590)
        field("추천 과정 · 학습 방향",x:left,y:613,width:content,height:37)
        field("수업 시작 희망일",x:left,y:650,width:half,height:35)
        field("다음 상담 · 체험 수업 일정",x:left+half,y:650,width:half,height:35)
        writingArea("상담자 메모 · 후속 안내",y:685,height:78)
        check("학생 목표 공유",x:left,y:781)
        check("수업 일정 안내",x:left+140,y:781)
        check("체험 수업 안내",x:left+280,y:781)
        line(CGPoint(x:left,y:806),CGPoint(x:right,y:806),width:0.5)
        text("LightNote  ·  신규 학생 상담",x:left,y:815,size:7.5,color:muted)
        text("A4  /  1",x:right-42,y:815,size:7.5,color:muted)
        bitmap.size = NSSize(width:width,height:height)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
