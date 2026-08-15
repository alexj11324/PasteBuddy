#if os(macOS)
import AppKit
import Foundation

extension Data {
    var pasteBuddyIsPNG: Bool {
        count >= 8 && starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    var pasteBuddyIsTIFF: Bool {
        starts(with: [0x49, 0x49, 0x2A, 0x00]) || starts(with: [0x4D, 0x4D, 0x00, 0x2A])
    }
}

extension NSImage {
    func pasteBuddyPNGData() -> Data? {
        guard
            let tiffData = tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
