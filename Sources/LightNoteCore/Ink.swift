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
    public var samples: [InkSample]
    public init(id: UUID = UUID(), color: InkColor = .black, width: Double = 1,
                samples: [InkSample]) {
        self.id = id; self.color = color; self.width = width; self.tool = "pen"; self.samples = samples
    }
    /// Swept eraser hit test: segment crossings count even when events are far apart.
    public func intersectsEraser(from start: CGPoint, to end: CGPoint, radius: CGFloat, polyline: [CGPoint]? = nil) -> Bool {
        let reach = radius + width / 2 + 0.000001
        let area = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -reach, dy: -reach)
        guard bounds.intersects(area) else { return false }
        let points = polyline ?? InkPathBuilder.make(samples: samples).points
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
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2)
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
            guard ids.insert(stroke.id).inserted, stroke.tool == "pen",
                  stroke.width.isFinite, (0.1...100).contains(stroke.width),
                  !stroke.samples.isEmpty else { throw NoteError.invalidData }
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
        return max(0, min(1, 1 - (now - releasedAt - 1) / 2))
    }
}
