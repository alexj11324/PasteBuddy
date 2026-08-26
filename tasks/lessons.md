# Lessons

## Image drag/paste
- OCR text is search metadata, not a paste representation. Advertising `public.utf8-plain-text` on an image `NSItemProvider` makes text fields (Cursor, Electron, NSTextView) take OCR instead of the image. Type identifier order does not win; the destination picks the type it prefers.
- `NSImage.writeObjects` / `tiffRepresentation` turns stored PNG into a huge uncompressed TIFF. Write stored PNG/TIFF bytes through. Convert only when the bytes are neither.
- Do not use `NSItemProvider(object: NSImage)` on the drag/copy path; it decodes eagerly and vends TIFF.
- PNG-only `registerDataRepresentation` is not enough for macOS drag. AppKit destinations want TIFF/`NSImage`; Finder, Electron, and chat composers want `registerFileRepresentation` (a real PNG file). Keep OCR text off, and register PNG + lazy TIFF + `NSImage` + file together. Set `suggestedName`.
- Do not build the `NSItemProvider` during SwiftUI `body`. Image cards re-render on thumbnail load and click-to-select; a captured provider from the previous body is replaced and the drop comes up empty. Create the provider inside the `.onDrag` closure.
- Unpinned Shelf/Side Panel hides on resign-active. Dragging a photo into another app deactivates PasteBuddy before the destination loads promised PNG/TIFF/file data. Keep the panel alive for the pointer session, drop `.transient` while that session is active, and delay hide until after mouse-up.
- X MCP was unavailable; Exa `site:x.com` returned no extra NSItemProvider drag hits. Apple docs: `registerFileRepresentation` load handler completion is `(url, coordinated, error)` — pass `coordinated=false` for a temp file we wrote.

## macOS 26 minimum
- SwiftPM: `.macOS("26.0")`. Info.plist / linker: `LSMinimumSystemVersion` and `-platform_version macos 26.0`.
- Raising the deployment target makes `#available(macOS 26.0, *)` unnecessary; unwrap it or the compiler warns and fallbacks become dead code.
- Official SPM docs expose `SupportedPlatform.MacOSVersion.v26` (PackageDescription 6.2+). String `"26.0"` works with tools 6.0.
- X MCP was unavailable; Exa `site:x.com` returned no extra deployment-target reports beyond Apple/SPM docs.

## Test builds on Desktop
- Desktop iCloud File Provider copies `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` onto `.xctest` bundles and ad-hoc `codesign` fails with “resource fork, Finder information, or similar detritus”. Use `~/Library/Developer/Xcode/DerivedData` as the SwiftPM scratch path.
