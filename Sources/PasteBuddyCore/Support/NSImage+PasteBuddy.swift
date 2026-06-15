#if os(macOS)
import AppKit
import Foundation

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
