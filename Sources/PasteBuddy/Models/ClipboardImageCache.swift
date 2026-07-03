import AppKit
import ImageIO
import PasteBuddyCore

@MainActor
enum ClipboardImageCache {
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 320
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private static let sizeCache: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 1_024
        return cache
    }()
    private static let genericApplicationIcon = icon(from: NSWorkspace.shared.icon(for: .applicationBundle))

    static func cachedThumbnail(for item: ClipboardItem, maxPixelSize: Int = 640) -> NSImage? {
        guard let key = thumbnailCacheKeyObject(for: item, maxPixelSize: maxPixelSize) else { return nil }
        return thumbnailCache.object(forKey: key)
    }

    static func thumbnail(for item: ClipboardItem, imageData: Data? = nil, maxPixelSize: Int = 640) async -> NSImage? {
        guard let data = imageData ?? item.payload.imageData,
              let key = thumbnailCacheKeyObject(for: item, maxPixelSize: maxPixelSize) else {
            return nil
        }
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        guard let cgImage = await Task.detached(priority: .utility, operation: {
            decodeThumbnail(from: data, maxPixelSize: maxPixelSize)
        }).value else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnailCache.setObject(image, forKey: key, cost: decodedImageCost(cgImage))
        return image
    }

    static func thumbnailCacheKey(for item: ClipboardItem, maxPixelSize: Int = 640) -> String? {
        thumbnailCacheKeyObject(for: item, maxPixelSize: maxPixelSize).map { $0 as String }
    }

    private static func thumbnailCacheKeyObject(for item: ClipboardItem, maxPixelSize: Int = 640) -> NSString? {
        guard item.payload.hasImageAsset else { return nil }
        return cacheKey(for: item, suffix: "thumb:\(maxPixelSize)")
    }

    static func imageSize(for item: ClipboardItem) -> NSSize? {
        guard let data = item.payload.imageData else { return nil }
        let key = cacheKey(for: item, suffix: "size")
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

    static func fittedDisplaySize(for imageSize: NSSize?, within maxSize: CGSize) -> CGSize {
        guard let imageSize,
              imageSize.width > 0,
              imageSize.height > 0,
              maxSize.width > 0,
              maxSize.height > 0 else {
            return maxSize
        }
        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func genericAppIcon() -> NSImage {
        genericApplicationIcon
    }

    private static func cacheKey(for item: ClipboardItem, suffix: String) -> NSString {
        let assetComponent = item.payload.imageAssetID ?? "inline"
        let byteCount = item.payload.imageData?.count ?? item.payload.imageByteCount ?? 0
        return "\(item.id.uuidString):\(item.updatedAt.timeIntervalSince1970):\(assetComponent):\(byteCount):\(suffix)" as NSString
    }

    nonisolated private static func decodeThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
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

    nonisolated private static func decodedImageCost(_ image: CGImage) -> Int {
        let byteCount = image.bytesPerRow * image.height
        return max(byteCount, 1)
    }

    private static func icon(from image: NSImage) -> NSImage {
        image.size = NSSize(width: 64, height: 64)
        return image
    }
}
