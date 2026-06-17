import AppKit
import SwiftUI

@MainActor
enum AppIconThemeColorResolver {
    private static let colorCache = NSCache<NSString, NSColor>()

    static func themeColor(for icon: NSImage?, cacheKey: String, fallback: Color) -> Color {
        guard let icon else { return fallback }

        let key = cacheKey as NSString
        if let cached = colorCache.object(forKey: key) {
            return Color(nsColor: cached)
        }

        guard let color = dominantColor(in: icon) else {
            return fallback
        }

        colorCache.setObject(color, forKey: key)
        return Color(nsColor: color)
    }

    static func dominantColor(in image: NSImage, sampleSize: Int = 40) -> NSColor? {
        guard sampleSize > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let pixelCount = sampleSize * sampleSize
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: pixelCount * bytesPerPixel)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: sampleSize,
                    height: sampleSize,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }

            context.clear(CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            return true
        }
        guard didDraw else { return nil }

        var chromaticBuckets: [Int: ColorBucket] = [:]
        var allBuckets: [Int: ColorBucket] = [:]

        for pixelIndex in 0..<pixelCount {
            let offset = pixelIndex * bytesPerPixel
            let alpha = CGFloat(pixels[offset + 3]) / 255
            guard alpha >= 0.35 else { continue }

            let red = min((CGFloat(pixels[offset]) / 255) / alpha, 1)
            let green = min((CGFloat(pixels[offset + 1]) / 255) / alpha, 1)
            let blue = min((CGFloat(pixels[offset + 2]) / 255) / alpha, 1)
            let brightness = max(red, green, blue)
            let minimum = min(red, green, blue)
            let saturation = brightness > 0 ? (brightness - minimum) / brightness : 0
            let weight = Double(alpha)

            allBuckets[quantizedKey(red: red, green: green, blue: blue), default: ColorBucket()]
                .add(red: red, green: green, blue: blue, weight: weight)

            if let score = chromaticScore(
                alpha: alpha,
                saturation: saturation,
                brightness: brightness,
                pixelIndex: pixelIndex,
                sampleSize: sampleSize
            ) {
                let key = quantizedChromaticKey(red: red, green: green, blue: blue)
                chromaticBuckets[key, default: ColorBucket()]
                    .add(red: red, green: green, blue: blue, weight: score)
            }
        }

        guard let bucket = strongestBucket(in: chromaticBuckets) ?? strongestBucket(in: allBuckets) else {
            return nil
        }

        return displayColor(red: bucket.averageRed, green: bucket.averageGreen, blue: bucket.averageBlue)
    }

    private static func chromaticScore(
        alpha: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat,
        pixelIndex: Int,
        sampleSize: Int
    ) -> Double? {
        guard saturation >= 0.18,
              brightness >= 0.16,
              !(brightness >= 0.94 && saturation < 0.45) else {
            return nil
        }

        let x = Double(pixelIndex % sampleSize) + 0.5
        let y = Double(pixelIndex / sampleSize) + 0.5
        let center = Double(sampleSize) / 2
        let normalizedDistance = min(hypot(x - center, y - center) / (center * sqrt(2)), 1)
        let centerWeight = 1.16 - normalizedDistance * 0.32
        let saturationWeight = pow(Double(saturation), 1.8)
        let brightnessWeight = 0.72 + min(Double(brightness), 0.95) * 0.28

        return Double(alpha) * saturationWeight * brightnessWeight * centerWeight
    }

    private static func quantizedChromaticKey(red: CGFloat, green: CGFloat, blue: CGFloat) -> Int {
        let color = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let hueBucket = min(max(Int((hue * 24).rounded(.down)), 0), 23)
        let saturationBucket = min(max(Int((saturation * 3).rounded(.down)), 0), 2)
        return (hueBucket << 8) | saturationBucket
    }

    private static func quantizedKey(red: CGFloat, green: CGFloat, blue: CGFloat) -> Int {
        let redBucket = min(max(Int((red * 11).rounded()), 0), 11)
        let greenBucket = min(max(Int((green * 11).rounded()), 0), 11)
        let blueBucket = min(max(Int((blue * 11).rounded()), 0), 11)
        return (redBucket << 16) | (greenBucket << 8) | blueBucket
    }

    private static func strongestBucket(in buckets: [Int: ColorBucket]) -> ColorBucket? {
        buckets.values.max { lhs, rhs in
            lhs.weight < rhs.weight
        }
    }

    private static func displayColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSColor {
        let color = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        if saturation < 0.12 {
            return NSColor(calibratedWhite: min(max(brightness, 0.28), 0.62), alpha: 1)
        }

        return NSColor(
            calibratedHue: hue,
            saturation: min(max(saturation, 0.36), 0.95),
            brightness: min(max(brightness, 0.38), 0.76),
            alpha: 1
        )
    }

    private struct ColorBucket {
        var redSum: Double = 0
        var greenSum: Double = 0
        var blueSum: Double = 0
        var weight: Double = 0

        mutating func add(red: CGFloat, green: CGFloat, blue: CGFloat, weight: Double) {
            redSum += Double(red) * weight
            greenSum += Double(green) * weight
            blueSum += Double(blue) * weight
            self.weight += weight
        }

        var averageRed: CGFloat {
            guard weight > 0 else { return 0 }
            return CGFloat(redSum / weight)
        }

        var averageGreen: CGFloat {
            guard weight > 0 else { return 0 }
            return CGFloat(greenSum / weight)
        }

        var averageBlue: CGFloat {
            guard weight > 0 else { return 0 }
            return CGFloat(blueSum / weight)
        }
    }
}
