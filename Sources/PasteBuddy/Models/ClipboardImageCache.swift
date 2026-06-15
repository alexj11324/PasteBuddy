import AppKit
import ImageIO
import PasteBuddyCore

enum ClipboardImageCache {
    private static let thumbnailCache = NSCache<NSString, NSImage>()
    private static let sizeCache = NSCache<NSString, NSValue>()
    private static let genericApplicationIcon = icon(from: NSWorkspace.shared.icon(for: .applicationBundle))

    static func cachedThumbnail(for item: ClipboardItem, maxPixelSize: Int = 640) -> NSImage? {
        guard let data = item.payload.imageData else { return nil }
        let key = thumbnailCacheKey(for: item, data: data, maxPixelSize: maxPixelSize)
        return thumbnailCache.object(forKey: key)
    }

    static func thumbnail(for item: ClipboardItem, maxPixelSize: Int = 640) async -> NSImage? {
        guard let data = item.payload.imageData else { return nil }
        let key = thumbnailCacheKey(for: item, data: data, maxPixelSize: maxPixelSize)
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        guard let cgImage = await Task.detached(priority: .utility, operation: {
            decodeThumbnail(from: data, maxPixelSize: maxPixelSize)
        }).value else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    static func thumbnailCacheKey(for item: ClipboardItem, maxPixelSize: Int = 640) -> String? {
        guard let data = item.payload.imageData else { return nil }
        return thumbnailCacheKey(for: item, data: data, maxPixelSize: maxPixelSize) as String
    }

    static func imageSize(for item: ClipboardItem) -> NSSize? {
        guard let data = item.payload.imageData else { return nil }
        let key = cacheKey(for: item, data: data, suffix: "size")
        if let cached = sizeCache.object(forKey: key) {
            return cached.sizeValue
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        let size = NSSize(width: width, height: height)
        sizeCache.setObject(NSValue(size: size), forKey: key)
        return size
    }

    static func genericAppIcon() -> NSImage {
        genericApplicationIcon
    }

    private static func cacheKey(for item: ClipboardItem, data: Data, suffix: String) -> NSString {
        "\(item.id.uuidString):\(data.count):\(item.updatedAt.timeIntervalSinceReferenceDate):\(suffix)" as NSString
    }

    private static func thumbnailCacheKey(for item: ClipboardItem, data: Data, maxPixelSize: Int) -> NSString {
        cacheKey(for: item, data: data, suffix: "thumb:\(maxPixelSize)")
    }

    private static func decodeThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func icon(from image: NSImage) -> NSImage {
        image.size = NSSize(width: 64, height: 64)
        return image
    }
}
