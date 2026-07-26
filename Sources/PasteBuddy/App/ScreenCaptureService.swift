import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PasteBuddyCore
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenCaptureServiceError: LocalizedError {
    case permissionRequired
    case noDisplay
    case emptyRegion
    case captureFailed
    case imageEncodingFailed
    case longCaptureLimitReached

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            NSLocalizedString("message.screen_recording_permission_is_required_for_screenshots", comment: "")
        case .noDisplay:
            NSLocalizedString("message.pastebuddy_could_not_identify_the_display_for", comment: "")
        case .emptyRegion:
            NSLocalizedString("message.select_a_non_empty_screenshot_region", comment: "")
        case .captureFailed:
            NSLocalizedString("message.the_screenshot_could_not_be_captured", comment: "")
        case .imageEncodingFailed:
            NSLocalizedString("message.the_screenshot_could_not_be_encoded_as", comment: "")
        case .longCaptureLimitReached:
            NSLocalizedString("message.the_long_screenshot_reached_its_safe_memory", comment: "")
        }
    }
}

struct CaptureDisplayGeometry: Equatable, Sendable {
    var appKitFrame: CGRect
    var quartzFrame: CGRect

    func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(
            x: quartzFrame.minX + rect.minX - appKitFrame.minX,
            y: quartzFrame.minY + appKitFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(
            x: appKitFrame.minX + rect.minX - quartzFrame.minX,
            y: appKitFrame.maxY - rect.maxY + quartzFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }
}

struct CapturedImageStyle: @unchecked Sendable {
    var cornerRadius: CGFloat = 0
    var borderWidth: CGFloat = 0
    var borderColor = CGColor(gray: 1, alpha: 0.9)
    var shadowRadius: CGFloat = 0

    static let plain = CapturedImageStyle()
}

struct ScreenCaptureService {
    var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestAuthorization() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func capture(
        quartzRect: CGRect,
        showsCursor: Bool
    ) async throws -> CGImage {
        let rect = quartzRect.integral
        guard rect.width >= 1, rect.height >= 1 else {
            throw ScreenCaptureServiceError.emptyRegion
        }
        guard isAuthorized else {
            throw ScreenCaptureServiceError.permissionRequired
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
            throw ScreenCaptureServiceError.noDisplay
        }
        let excludedApplications: [SCRunningApplication]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            excludedApplications = content.applications.filter {
                $0.bundleIdentifier == bundleIdentifier
            }
        } else {
            excludedApplications = []
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let localRect = CGRect(
            x: rect.minX - display.frame.minX,
            y: rect.minY - display.frame.minY,
            width: min(rect.width, display.frame.maxX - rect.minX),
            height: min(rect.height, display.frame.maxY - rect.minY)
        )
        let scale = scaleFactor(forQuartzRect: rect)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = max(1, Int(localRect.width * scale))
        configuration.height = max(1, Int(localRect.height * scale))
        configuration.showsCursor = showsCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    func displayGeometry(containingAppKit point: CGPoint) -> CaptureDisplayGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? CGDirectDisplayID else {
            return nil
        }
        return CaptureDisplayGeometry(
            appKitFrame: screen.frame,
            quartzFrame: CGDisplayBounds(displayID)
        )
    }

    func quartzRect(fromAppKit rect: CGRect) throws -> CGRect {
        guard let geometry = displayGeometry(
            containingAppKit: CGPoint(x: rect.midX, y: rect.midY)
        ) else {
            throw ScreenCaptureServiceError.noDisplay
        }
        return geometry.quartzRect(fromAppKit: rect)
    }

    private func scaleFactor(forQuartzRect rect: CGRect) -> CGFloat {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayBounds(id).intersects(rect)
        }) else {
            return NSScreen.main?.backingScaleFactor ?? 2
        }
        return screen.backingScaleFactor
    }
}

enum CapturedImageRenderer {
    static func render(_ image: CGImage, style: CapturedImageStyle) throws -> CGImage {
        let shadowInset = ceil(max(0, style.shadowRadius) * 2)
        let outputWidth = image.width + Int(shadowInset * 2)
        let outputHeight = image.height + Int(shadowInset * 2)
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenCaptureServiceError.captureFailed
        }

        let imageRect = CGRect(
            x: shadowInset,
            y: shadowInset,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        let radius = min(
            max(0, style.cornerRadius),
            min(imageRect.width, imageRect.height) / 2
        )
        let path = CGPath(
            roundedRect: imageRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.saveGState()
        if style.shadowRadius > 0 {
            context.setShadow(
                offset: CGSize(width: 0, height: -style.shadowRadius / 3),
                blur: style.shadowRadius,
                color: CGColor(gray: 0, alpha: 0.42)
            )
        }
        context.addPath(path)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()

        if style.borderWidth > 0 {
            context.addPath(path)
            context.setLineWidth(style.borderWidth)
            context.setStrokeColor(style.borderColor)
            context.strokePath()
        }
        guard let rendered = context.makeImage() else {
            throw ScreenCaptureServiceError.captureFailed
        }
        return rendered
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenCaptureServiceError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenCaptureServiceError.imageEncodingFailed
        }
        return data as Data
    }
}

struct LongScreenshotAccumulator {
    struct Segment {
        var image: CGImage
        var overlap: Int
    }

    private(set) var direction: LongScreenshotDirection
    private(set) var segments: [Segment] = []
    private(set) var width = 0
    private(set) var height = 0
    private(set) var storedPixelCount = 0
    var limits = LongScreenshotLimits.default
    var matcher = LongScreenshotOverlapMatcher()

    init(direction: LongScreenshotDirection) {
        self.direction = direction
    }

    mutating func append(_ image: CGImage) throws -> LongScreenshotMatch {
        guard let previous = segments.last?.image else {
            let (sourcePixels, sourceOverflow) = image.width.multipliedReportingOverflow(
                by: image.height
            )
            guard !sourceOverflow,
                  limits.permits(width: image.width, height: image.height, frameCount: 1),
                  limits.permitsStoredPixelCount(sourcePixels) else {
                throw ScreenCaptureServiceError.longCaptureLimitReached
            }
            segments = [Segment(image: image, overlap: 0)]
            width = image.width
            height = image.height
            storedPixelCount = sourcePixels
            return .matched(overlap: 0, score: 0)
        }

        let match = matcher.match(
            previous: try LongScreenshotRaster(image: previous),
            current: try LongScreenshotRaster(image: image),
            direction: direction
        )
        guard case .matched(let overlap, _) = match else {
            return match
        }
        let nextWidth: Int
        let nextHeight: Int
        switch direction {
        case .vertical:
            nextWidth = max(width, image.width)
            nextHeight = height + image.height - overlap
        case .horizontal:
            nextWidth = width + image.width - overlap
            nextHeight = max(height, image.height)
        }
        let (sourcePixels, sourceOverflow) = image.width.multipliedReportingOverflow(
            by: image.height
        )
        let (nextStoredPixelCount, storedOverflow) = storedPixelCount.addingReportingOverflow(
            sourcePixels
        )
        guard !sourceOverflow,
              !storedOverflow,
              limits.permitsStoredPixelCount(nextStoredPixelCount),
              limits.permits(
            width: nextWidth,
            height: nextHeight,
            frameCount: segments.count + 1
        ) else {
            throw ScreenCaptureServiceError.longCaptureLimitReached
        }
        segments.append(Segment(image: image, overlap: overlap))
        width = nextWidth
        height = nextHeight
        storedPixelCount = nextStoredPixelCount
        return match
    }

    func renderedImage(leadingCrop: Int = 0, trailingCrop: Int = 0) throws -> CGImage {
        guard !segments.isEmpty else {
            throw ScreenCaptureServiceError.captureFailed
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenCaptureServiceError.captureFailed
        }
        context.interpolationQuality = .none

        switch direction {
        case .vertical:
            var top = height
            for (index, segment) in segments.enumerated() {
                let crop = index == 0 ? 0 : segment.overlap
                let visibleHeight = segment.image.height - crop
                top -= visibleHeight
                let source = try cropped(
                    segment.image,
                    rect: CGRect(
                        x: 0,
                        y: crop,
                        width: segment.image.width,
                        height: visibleHeight
                    )
                )
                context.draw(
                    source,
                    in: CGRect(x: 0, y: top, width: source.width, height: source.height)
                )
            }
        case .horizontal:
            var left = 0
            for (index, segment) in segments.enumerated() {
                let crop = index == 0 ? 0 : segment.overlap
                let visibleWidth = segment.image.width - crop
                let source = try cropped(
                    segment.image,
                    rect: CGRect(
                        x: crop,
                        y: 0,
                        width: visibleWidth,
                        height: segment.image.height
                    )
                )
                context.draw(
                    source,
                    in: CGRect(x: left, y: 0, width: source.width, height: source.height)
                )
                left += visibleWidth
            }
        }
        guard let combined = context.makeImage() else {
            throw ScreenCaptureServiceError.captureFailed
        }

        let axisLength = direction == .vertical ? combined.height : combined.width
        let safeLeadingCrop = min(max(0, leadingCrop), max(0, axisLength - 1))
        let safeTrailingCrop = min(
            max(0, trailingCrop),
            max(0, axisLength - safeLeadingCrop - 1)
        )
        let cropRect: CGRect
        switch direction {
        case .vertical:
            cropRect = CGRect(
                x: 0,
                y: safeLeadingCrop,
                width: combined.width,
                height: combined.height - safeLeadingCrop - safeTrailingCrop
            )
        case .horizontal:
            cropRect = CGRect(
                x: safeLeadingCrop,
                y: 0,
                width: combined.width - safeLeadingCrop - safeTrailingCrop,
                height: combined.height
            )
        }
        return try cropped(combined, rect: cropRect)
    }

    private func cropped(_ image: CGImage, rect: CGRect) throws -> CGImage {
        guard let cropped = image.cropping(to: rect.integral) else {
            throw ScreenCaptureServiceError.captureFailed
        }
        return cropped
    }
}

private extension LongScreenshotRaster {
    init(image: CGImage) throws {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard rendered else {
            throw ScreenCaptureServiceError.captureFailed
        }
        self.init(width: image.width, height: image.height, grayscalePixels: pixels)
    }
}

@MainActor
struct CapturedImageHistoryWriter {
    let store: PasteBuddyStore

    func storeImage(_ image: CGImage, titleKey: String) throws -> ClipboardItem {
        let data = try CapturedImageRenderer.pngData(image)
        let item = ClipboardItem(
            sourceAppName: "PasteBuddy",
            sourceBundleIdentifier: Bundle.main.bundleIdentifier,
            deviceName: Host.current().localizedName
                ?? NSLocalizedString("label.this_mac", comment: ""),
            contentType: .image,
            title: NSLocalizedString(titleKey, comment: ""),
            payload: ClipboardPayload(imageData: data),
            ocrState: store.snapshot.privacy.runLocalOCRAfterImageCapture
                ? .pending(Date())
                : .notNeeded
        )
        let stored = store.addCapturedItem(item)
        if store.snapshot.privacy.runLocalOCRAfterImageCapture {
            Task { @MainActor [weak store] in
                do {
                    let text = try await OCRService().recognizeText(in: data)
                    store?.updateOCRText(text, for: stored.id)
                } catch {
                    store?.markOCRFailed(error.localizedDescription, for: stored.id)
                }
            }
        }
        return stored
    }
}
