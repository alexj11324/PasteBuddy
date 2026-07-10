import Foundation
import ImageIO
import PasteBuddyCore

public enum MobileImageSafetyError: LocalizedError, Equatable {
    case compressedDataTooLarge(actualBytes: Int, limitBytes: Int)
    case invalidImageData
    case pixelCountTooLarge(width: Int, height: Int, limit: Int)
    case frameCountTooLarge(actual: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .compressedDataTooLarge(_, let limitBytes):
            PasteBuddyLocalization.format(
                "mobile.error.image_data_too_large",
                defaultValue: "The shared image is too large to import safely (limit: %d MB).",
                max(limitBytes / (1_024 * 1_024), 1)
            )
        case .invalidImageData:
            PasteBuddyLocalization.string(
                "mobile.error.invalid_image_data",
                defaultValue: "The shared image data is invalid."
            )
        case .pixelCountTooLarge:
            PasteBuddyLocalization.string(
                "mobile.error.image_dimensions_too_large",
                defaultValue: "The shared image dimensions are too large to process safely."
            )
        case .frameCountTooLarge:
            PasteBuddyLocalization.string(
                "mobile.error.image_frame_count_too_large",
                defaultValue: "The shared image contains too many frames to process safely."
            )
        }
    }
}

public struct MobileImageSafetyPolicy: Equatable, Sendable {
    public static let `default` = MobileImageSafetyPolicy(
        maxCompressedBytes: 32 * 1_024 * 1_024,
        maxPixelCount: 64_000_000,
        maxFrameCount: 64
    )

    public var maxCompressedBytes: Int
    public var maxPixelCount: Int
    public var maxFrameCount: Int

    public init(
        maxCompressedBytes: Int,
        maxPixelCount: Int,
        maxFrameCount: Int = 64
    ) {
        self.maxCompressedBytes = max(maxCompressedBytes, 1)
        self.maxPixelCount = max(maxPixelCount, 1)
        self.maxFrameCount = max(maxFrameCount, 1)
    }

    public func validate(_ data: Data) throws -> String {
        try validateCompressedByteCount(data.count)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source) as String? else {
            throw MobileImageSafetyError.invalidImageData
        }
        let frameCount = CGImageSourceGetCount(source)
        try validateFrameCount(frameCount)
        var remainingPixelCount = maxPixelCount
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0,
                  height > 0 else {
                throw MobileImageSafetyError.invalidImageData
            }
            guard width <= remainingPixelCount / height else {
                throw MobileImageSafetyError.pixelCountTooLarge(
                    width: width,
                    height: height,
                    limit: maxPixelCount
                )
            }
            remainingPixelCount -= width * height
        }
        return typeIdentifier
    }

    func validateCompressedByteCount(_ byteCount: Int) throws {
        guard byteCount <= maxCompressedBytes else {
            throw MobileImageSafetyError.compressedDataTooLarge(
                actualBytes: byteCount,
                limitBytes: maxCompressedBytes
            )
        }
    }

    func validateDimensions(width: Int, height: Int) throws {
        guard width > 0,
              height > 0,
              width <= maxPixelCount / height else {
            throw MobileImageSafetyError.pixelCountTooLarge(
                width: width,
                height: height,
                limit: maxPixelCount
            )
        }
    }

    func validateFrameCount(_ frameCount: Int) throws {
        guard frameCount > 0, frameCount <= maxFrameCount else {
            throw MobileImageSafetyError.frameCountTooLarge(
                actual: frameCount,
                limit: maxFrameCount
            )
        }
    }
}
