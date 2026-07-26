import CoreGraphics
import Foundation

enum CaptureAspectLock: Equatable, Sendable {
    case free
    case square
    case ratio(CGFloat)

    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .ratio(let value): max(value, 0.01)
        }
    }
}

struct CaptureSelectionGeometry {
    static let minimumSize = CGSize(width: 8, height: 8)

    static func selection(
        from start: CGPoint,
        to end: CGPoint,
        in bounds: CGRect,
        aspectLock: CaptureAspectLock
    ) -> CGRect {
        let origin = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
        var size = CGSize(width: abs(end.x - start.x), height: abs(end.y - start.y))
        if let ratio = aspectLock.ratio {
            if size.width / max(size.height, 1) > ratio {
                size.width = size.height * ratio
            } else {
                size.height = size.width / ratio
            }
        }
        let signedOrigin = CGPoint(
            x: end.x >= start.x ? origin.x : start.x - size.width,
            y: end.y >= start.y ? origin.y : start.y - size.height
        )
        return clamped(
            CGRect(origin: signedOrigin, size: size),
            to: bounds
        )
    }

    static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat, in bounds: CGRect) -> CGRect {
        clamped(rect.offsetBy(dx: dx, dy: dy), to: bounds, preservingSize: true)
    }

    static func resized(
        _ rect: CGRect,
        width: CGFloat,
        height: CGFloat,
        in bounds: CGRect,
        aspectLock: CaptureAspectLock
    ) -> CGRect {
        var targetSize = CGSize(
            width: max(minimumSize.width, width),
            height: max(minimumSize.height, height)
        )
        if let ratio = aspectLock.ratio {
            targetSize.height = targetSize.width / ratio
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return clamped(
            CGRect(
                x: center.x - targetSize.width / 2,
                y: center.y - targetSize.height / 2,
                width: targetSize.width,
                height: targetSize.height
            ),
            to: bounds
        )
    }

    static func resizedEdge(
        _ rect: CGRect,
        dx: CGFloat,
        dy: CGFloat,
        grow: Bool,
        in bounds: CGRect
    ) -> CGRect {
        var adjusted = rect
        if dx < 0 {
            let delta: CGFloat = grow ? -1 : 1
            adjusted.origin.x += delta
            adjusted.size.width -= delta
        } else if dx > 0 {
            adjusted.size.width += grow ? 1 : -1
        }
        if dy < 0 {
            let delta: CGFloat = grow ? -1 : 1
            adjusted.origin.y += delta
            adjusted.size.height -= delta
        } else if dy > 0 {
            adjusted.size.height += grow ? 1 : -1
        }
        return clamped(adjusted, to: bounds)
    }

    static func clamped(
        _ rect: CGRect,
        to bounds: CGRect,
        preservingSize: Bool = false
    ) -> CGRect {
        let standardized = rect.standardized
        let width = min(
            bounds.width,
            max(preservingSize ? standardized.width : minimumSize.width, standardized.width)
        )
        let height = min(
            bounds.height,
            max(preservingSize ? standardized.height : minimumSize.height, standardized.height)
        )
        return CGRect(
            x: min(max(standardized.minX, bounds.minX), bounds.maxX - width),
            y: min(max(standardized.minY, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }
}

enum LongScreenshotDirection: String, CaseIterable, Sendable {
    case vertical
    case horizontal
}

struct LongScreenshotLimits: Equatable, Sendable {
    static let `default` = LongScreenshotLimits(
        maximumPixelCount: 64_000_000,
        maximumDimension: 80_000,
        maximumFrameCount: 500,
        maximumStoredPixelCount: 96_000_000
    )

    var maximumPixelCount: Int
    var maximumDimension: Int
    var maximumFrameCount: Int
    var maximumStoredPixelCount: Int

    func permits(width: Int, height: Int, frameCount: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumDimension,
              height <= maximumDimension,
              frameCount <= maximumFrameCount else {
            return false
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= maximumPixelCount
    }

    func permitsStoredPixelCount(_ pixelCount: Int) -> Bool {
        pixelCount > 0 && pixelCount <= maximumStoredPixelCount
    }
}

struct LongScreenshotRaster: Equatable, Sendable {
    let width: Int
    let height: Int
    let grayscalePixels: [UInt8]

    init(width: Int, height: Int, grayscalePixels: [UInt8]) {
        precondition(width > 0 && height > 0)
        precondition(grayscalePixels.count == width * height)
        self.width = width
        self.height = height
        self.grayscalePixels = grayscalePixels
    }

    subscript(x: Int, y: Int) -> UInt8 {
        grayscalePixels[y * width + x]
    }
}

enum LongScreenshotMatch: Equatable, Sendable {
    case matched(overlap: Int, score: Double)
    case noMovement
    case noMatch(bestScore: Double?)
    case ambiguous(bestScore: Double)
}

struct LongScreenshotOverlapMatcher {
    var maximumMeanDifference = 16.0
    var minimumUniquenessGap = 1.25

    func match(
        previous: LongScreenshotRaster,
        current: LongScreenshotRaster,
        direction: LongScreenshotDirection
    ) -> LongScreenshotMatch {
        let axisLength: Int
        let crossLength: Int
        switch direction {
        case .vertical:
            guard previous.width == current.width else { return .noMatch(bestScore: nil) }
            axisLength = min(previous.height, current.height)
            crossLength = previous.width
        case .horizontal:
            guard previous.height == current.height else { return .noMatch(bestScore: nil) }
            axisLength = min(previous.width, current.width)
            crossLength = previous.height
        }
        guard axisLength >= 24, crossLength >= 4 else { return .noMatch(bestScore: nil) }

        let fullFrameScore = difference(
            previous: previous,
            current: current,
            overlap: axisLength,
            direction: direction
        )
        if fullFrameScore < 0.5 {
            return .noMovement
        }

        let minimumOverlap = max(12, axisLength / 10)
        let maximumOverlap = max(minimumOverlap, axisLength * 9 / 10)
        let coarseStep = max(1, axisLength / 256)
        var scores: [(overlap: Int, score: Double)] = stride(
            from: minimumOverlap,
            through: maximumOverlap,
            by: coarseStep
        ).map { overlap -> (overlap: Int, score: Double) in
            (
                overlap,
                difference(
                    previous: previous,
                    current: current,
                    overlap: overlap,
                    direction: direction
                )
            )
        }
        guard let coarseBest = scores.min(by: { $0.score < $1.score }) else {
            return .noMatch(bestScore: nil)
        }
        let refinementRange = (
            max(minimumOverlap, coarseBest.overlap - coarseStep)
                ... min(maximumOverlap, coarseBest.overlap + coarseStep)
        )
        for overlap in refinementRange {
            scores.append((
                overlap,
                difference(
                    previous: previous,
                    current: current,
                    overlap: overlap,
                    direction: direction
                )
            ))
        }
        scores.sort { $0.score < $1.score }
        guard let best = scores.first else { return .noMatch(bestScore: nil) }
        guard best.score <= maximumMeanDifference else {
            return .noMatch(bestScore: best.score)
        }
        let distinctSecond = scores.first {
            abs($0.overlap - best.overlap) >= 4
        }
        if let distinctSecond,
           distinctSecond.score - best.score < minimumUniquenessGap {
            return .ambiguous(bestScore: best.score)
        }
        return .matched(overlap: best.overlap, score: best.score)
    }

    private func difference(
        previous: LongScreenshotRaster,
        current: LongScreenshotRaster,
        overlap: Int,
        direction: LongScreenshotDirection
    ) -> Double {
        let axisStep = max(1, overlap / 64)
        let crossLength = direction == .vertical ? previous.width : previous.height
        let crossStep = max(1, crossLength / 64)
        let previousAxisLength = direction == .vertical ? previous.height : previous.width
        var total = 0
        var count = 0
        var axis = 0
        while axis < overlap {
            var cross = 0
            while cross < crossLength {
                let previousValue: UInt8
                let currentValue: UInt8
                switch direction {
                case .vertical:
                    previousValue = previous[cross, previousAxisLength - overlap + axis]
                    currentValue = current[cross, axis]
                case .horizontal:
                    previousValue = previous[previousAxisLength - overlap + axis, cross]
                    currentValue = current[axis, cross]
                }
                total += abs(Int(previousValue) - Int(currentValue))
                count += 1
                cross += crossStep
            }
            axis += axisStep
        }
        return count == 0 ? .infinity : Double(total) / Double(count)
    }
}
