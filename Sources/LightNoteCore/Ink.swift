import Foundation
import CoreGraphics

public struct InkColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let black = InkColor(0.08, 0.09, 0.12)
    public static let blue = InkColor(0.15, 0.35, 0.85)
    public static let red = InkColor(0.85, 0.18, 0.22)
    public static let green = InkColor(0.08, 0.52, 0.36)
    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }
}

public struct InkSample: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var time: Double
    public var pressure: Double?
    public init(x: Double, y: Double, time: Double, pressure: Double? = nil) {
        self.x = x; self.y = y; self.time = time; self.pressure = pressure
    }
    public var point: CGPoint { CGPoint(x: x, y: y) }
}

public struct InkStroke: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var color: InkColor
    public var width: Double
    public var tool: String
    public var locked: Bool? = nil
    public var isLocked: Bool { locked == true }
    public var imagePNG: Data? = nil
    public var samples: [InkSample]
    public init(id: UUID = UUID(), color: InkColor = .black, width: Double = 1,
                samples: [InkSample]) {
        self.id = id; self.color = color; self.width = width; self.tool = "pen"; self.samples = samples
    }
    /// Swept eraser hit test: segment crossings count even when events are far apart.
    public func intersectsEraser(from start: CGPoint, to end: CGPoint, radius: CGFloat, polyline: [CGPoint]? = nil) -> Bool {
        guard tool != "image" else { return false }
        let reach = radius + width / 2 + 0.000001
        let area = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -reach, dy: -reach)
        guard bounds.intersects(area) else { return false }
        let points = polyline ?? InkPathBuilder.make(stroke: self).points
        guard let first = points.first else { return false }
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((p.x-a.x)*dx + (p.y-a.y)*dy) / length))
            return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
        }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
        }
        if distance(first, start, end) <= reach { return true }
        for i in points.indices.dropFirst() {
            let a = points[i-1], b = points[i]
            let c1 = cross(start, end, a), c2 = cross(start, end, b)
            let c3 = cross(a, b, start), c4 = cross(a, b, end)
            if ((c1 < 0 && c2 > 0) || (c1 > 0 && c2 < 0)),
               ((c3 < 0 && c4 > 0) || (c3 > 0 && c4 < 0)) { return true }
            if min(distance(a, start, end), distance(b, start, end),
                   distance(start, a, b), distance(end, a, b)) <= reach { return true }
        }
        return false
    }

    public var bounds: CGRect {
        guard let first = samples.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in samples.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for point in freeArrowHead {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return tool == "image" ? rect : rect.insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2)
    }
}

public enum PaperStyle: String, Codable, CaseIterable, Sendable {
    case blank, grid
}

public struct NoteFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int = currentVersion
    public var pageWidth: Double = 794
    public var pageHeight: Double = 1123
    public var paperStyle: PaperStyle = .grid
    public var strokes: [InkStroke] = []
    public init(strokes: [InkStroke] = []) { self.strokes = strokes }

    private enum CodingKeys: String, CodingKey {
        case version, pageWidth, pageHeight, paperStyle, strokes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        pageWidth = try values.decode(Double.self, forKey: .pageWidth)
        pageHeight = try values.decode(Double.self, forKey: .pageHeight)
        // Documents created before paper styles were introduced remain plain paper.
        paperStyle = try values.decodeIfPresent(PaperStyle.self, forKey: .paperStyle) ?? .blank
        strokes = try values.decode([InkStroke].self, forKey: .strokes)
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }
    public static func decode(_ data: Data) throws -> NoteFile {
        let note = try JSONDecoder().decode(NoteFile.self, from: data)
        try note.validate()
        return note
    }
    // Validate before replacing the open document, including values that could break rendering.
    public func validate() throws {
        guard version == Self.currentVersion else { throw NoteError.unsupportedVersion(version) }
        guard pageWidth.isFinite, pageHeight.isFinite,
              (100...10000).contains(pageWidth), (100...10000).contains(pageHeight) else {
            throw NoteError.invalidData
        }
        var ids = Set<UUID>()
        for stroke in strokes {
            guard ids.insert(stroke.id).inserted, ["pen", "ellipse", "rectangle", "arrow", "freeArrow", "image"].contains(stroke.tool),
                  stroke.width.isFinite, (0.1...100).contains(stroke.width),
                  !stroke.samples.isEmpty else { throw NoteError.invalidData }
            if stroke.tool == "image" {
                guard let data = stroke.imagePNG, data.count <= 50_000_000,
                      data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                      stroke.samples.count == 2,
                      abs(stroke.samples[1].x - stroke.samples[0].x) > 0,
                      abs(stroke.samples[1].y - stroke.samples[0].y) > 0 else { throw NoteError.invalidData }
            }
            for c in [stroke.color.red, stroke.color.green, stroke.color.blue, stroke.color.alpha] {
                guard c.isFinite, (0...1).contains(c) else { throw NoteError.invalidData }
            }
            for p in stroke.samples {
                guard p.x.isFinite, p.y.isFinite, abs(p.x) <= 100000, abs(p.y) <= 100000,
                      p.time.isFinite else { throw NoteError.invalidData }
                if let pressure = p.pressure, !pressure.isFinite || !(0...1).contains(pressure) {
                    throw NoteError.invalidData
                }
            }
        }
    }
}

public enum NoteError: LocalizedError {
    case unsupportedVersion(Int), invalidData
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "지원하지 않는 LightNote 문서 버전입니다 (\(version))."
        case .invalidData: return "문서의 필기 데이터가 올바르지 않습니다. 원본 파일은 변경하지 않았습니다."
        }
    }
}

/// Incremental, shape-preserving cubic interpolation through every distinct input point.
/// One segment waits for the next tangent; the live preview still reaches the newest sample.
public final class InkPathBuilder {
    public let path = CGMutablePath()
    public private(set) var points: [CGPoint] = []
    public private(set) var lastPoint: CGPoint?
    private var pendingStart: CGPoint?
    private var beforePending: CGPoint?
    private let spacing: CGFloat = 0.5

    public init() {}
    private func tangent(_ before: CGPoint?, _ current: CGPoint, _ after: CGPoint?) -> CGPoint {
        guard let before else {
            return CGPoint(x: (after?.x ?? current.x)-current.x, y: (after?.y ?? current.y)-current.y)
        }
        guard let after else { return CGPoint(x: current.x-before.x, y: current.y-before.y) }
        func component(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            // At extrema or intentional reversals, avoid overshoot and tiny loops.
            guard a * b > 0 else { return 0 }
            return 2 * a * b / (a + b)
        }
        return CGPoint(x: component(current.x-before.x, after.x-current.x),
                       y: component(current.y-before.y, after.y-current.y))
    }
    private func segment(from start: CGPoint, to end: CGPoint, next: CGPoint?) {
        let first = tangent(beforePending, start, end)
        let second = tangent(start, end, next)
        let c1 = CGPoint(x: start.x + first.x/3, y: start.y + first.y/3)
        let c2 = CGPoint(x: end.x - second.x/3, y: end.y - second.y/3)
        let maxEdge = max(hypot(c1.x-start.x, c1.y-start.y), hypot(c2.x-c1.x, c2.y-c1.y),
                          hypot(end.x-c2.x, end.y-c2.y))
        let steps = max(2, min(4096, Int(ceil(3 * maxEdge / spacing))))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps), u = 1-t
            let p = i == steps ? end : CGPoint(
                x: u*u*u*start.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*end.x,
                y: u*u*u*start.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*end.y)
            path.addLine(to: p)
            points.append(p)
        }
    }
    public func append(_ point: CGPoint) {
        guard let previous = lastPoint else {
            path.move(to: point); points.append(point); lastPoint = point
            return
        }
        guard point != previous else { return }
        if let start = pendingStart {
            segment(from: start, to: previous, next: point)
            beforePending = start
        }
        pendingStart = previous
        lastPoint = point
    }
    public func finish() {
        if let start = pendingStart, let lastPoint {
            segment(from: start, to: lastPoint, next: nil)
            pendingStart = nil
        }
    }
    public static func make(stroke: InkStroke) -> InkPathBuilder {
        guard stroke.tool != "pen" else { return make(samples: stroke.samples) }
        if stroke.tool == "freeArrow" {
            let builder = make(samples: stroke.samples)
            let head = stroke.freeArrowHead
            if !head.isEmpty { builder.path.addLines(between: head); builder.points.append(contentsOf: head) }
            return builder
        }
        let builder = InkPathBuilder()
        builder.points = stroke.samples.map(\.point)
        let rect = stroke.pointBounds
        if stroke.tool == "ellipse" { builder.path.addEllipse(in: rect) }
        else if stroke.tool == "arrow" { builder.path.addLines(between: builder.points) }
        else { builder.path.addRect(rect) }
        return builder
    }
    public static func make(samples: [InkSample]) -> InkPathBuilder {
        let builder = InkPathBuilder()
        for sample in samples { builder.append(sample.point) }
        builder.finish()
        return builder
    }
}

/// Transient laser timing is separate from persistent ink and uses monotonic uptime.
public enum LaserTiming {
    public static func opacity(releasedAt: TimeInterval?, now: TimeInterval) -> Double {
        guard let releasedAt else { return 1 }
        return max(0, min(1, 1 - (now - releasedAt) / 1.3))
    }
}

public enum InkShapeKind: String, Sendable { case ellipse, rectangle, arrow }

extension InkStroke {
    public var pointBounds: CGRect {
        guard let first = samples.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in samples.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX-minX, height: maxY-minY)
    }
    public static func shape(_ kind: InkShapeKind, from start: CGPoint, to end: CGPoint,
                             constrained: Bool, color: InkColor, width: Double,
                             id: UUID = UUID(), time: Double = 0) -> InkStroke? {
        var dx = end.x-start.x, dy = end.y-start.y
        if kind == .arrow {
            let length = hypot(dx, dy)
            guard length >= 1 else { return nil }
            let ux = dx/length, uy = dy/length
            let head = min(length * 0.3, max(10, width*4))
            let wing1 = CGPoint(x: end.x-ux*head-uy*head*0.5, y: end.y-uy*head+ux*head*0.5)
            let wing2 = CGPoint(x: end.x-ux*head+uy*head*0.5, y: end.y-uy*head-ux*head*0.5)
            var stroke = InkStroke(id: id, color: color, width: width,
                samples: [start, end, wing1, end, wing2].map { InkSample(x: $0.x, y: $0.y, time: time) })
            stroke.tool = "arrow"
            return stroke
        }
        if constrained {
            let size = max(abs(dx), abs(dy))
            dx = (dx < 0 ? -1 : 1) * size; dy = (dy < 0 ? -1 : 1) * size
        }
        let rect = CGRect(x: min(start.x, start.x+dx), y: min(start.y, start.y+dy), width: abs(dx), height: abs(dy))
        guard rect.width >= 0.1, rect.height >= 0.1 else { return nil }
        var points: [CGPoint]
        if kind == .rectangle {
            points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                      CGPoint(x: rect.minX, y: rect.minY)]
        } else {
            let steps = max(64, min(2048, Int(ceil(.pi * (rect.width+rect.height) / 0.75 / 4)) * 4))
            points = (0..<steps).map { i in
                let angle = CGFloat(i) * 2 * .pi / CGFloat(steps)
                return CGPoint(x: rect.midX + rect.width/2*cos(angle), y: rect.midY + rect.height/2*sin(angle))
            }
            points.append(points[0])
        }
        var stroke = InkStroke(id: id, color: color, width: width,
            samples: points.map { InkSample(x: $0.x, y: $0.y, time: time) })
        stroke.tool = kind.rawValue
        return stroke
    }
}

extension InkStroke {
    public func copied(offset: CGSize) -> InkStroke {
        var copy = self
        copy.id = UUID()
        for index in copy.samples.indices {
            copy.samples[index].x += offset.width
            copy.samples[index].y += offset.height
        }
        return copy
    }
}


extension InkStroke {
    /// A short arc-length lookback stabilizes release jitter without straightening the shaft.
    /// Only the recent tail is visited, so live preview does not rescan long strokes.
    public var freeArrowHead: [CGPoint] {
        guard tool == "freeArrow", let tip = samples.last?.point, samples.count > 1 else { return [] }
        let desired = max(10, width * 4)
        let lookback = min(8, max(4, desired * 0.6))
        let budget = desired / 0.35
        var length: CGFloat = 0
        var previous = tip
        var anchor: CGPoint?
        var nearest: CGPoint?
        for sample in samples.dropLast().reversed() {
            let point = sample.point
            let distance = hypot(point.x-previous.x, point.y-previous.y)
            guard distance > 0 else { continue }
            if nearest == nil { nearest = point }
            if anchor == nil, length + distance >= lookback {
                let t = (lookback-length)/distance
                anchor = CGPoint(x: previous.x+(point.x-previous.x)*t, y: previous.y+(point.y-previous.y)*t)
            }
            length += distance
            previous = point
            if length >= budget { break }
        }
        guard length >= 1 else { return [] }
        var start = anchor ?? previous
        if hypot(tip.x-start.x, tip.y-start.y) < 0.0001, let nearest { start = nearest }
        let distance = hypot(tip.x-start.x, tip.y-start.y)
        guard distance > 0.0001 else { return [] }
        let ux = (tip.x-start.x)/distance, uy = (tip.y-start.y)/distance
        let size = min(desired, length * 0.35)
        return [CGPoint(x: tip.x-ux*size-uy*size*0.5, y: tip.y-uy*size+ux*size*0.5),
                tip, CGPoint(x: tip.x-ux*size+uy*size*0.5, y: tip.y-uy*size-ux*size*0.5)]
    }
    public var freeArrowHeadBounds: CGRect {
        let head = freeArrowHead
        guard let first = head.first else { return .null }
        return head.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            CGRect(x: min(rect.minX,point.x), y: min(rect.minY,point.y),
                   width: max(rect.maxX,point.x)-min(rect.minX,point.x), height: max(rect.maxY,point.y)-min(rect.minY,point.y))
        }
    }
}


extension InkStroke {
    /// A constrained pen stroke remains ordinary ink for copying, erasing and old notes.
    public func straightened() -> InkStroke {
        guard tool == "pen", let first = samples.first, let last = samples.last else { return self }
        var copy = self
        copy.samples = [first, last]
        return copy
    }
}
