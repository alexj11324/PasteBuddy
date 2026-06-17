import AppKit
import Carbon
import XCTest
@testable import PasteBuddy

@MainActor
final class PasteBuddyAppRuntimeTests: XCTestCase {
    func testAppDelegateDoesNotReopenMainWindowWhenNoWindowsAreVisible() {
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        )
        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        )
    }

    func testRuntimeLoadGateInvokesAsyncLoadOnlyOnce() async {
        let gate = PasteBuddyRuntimeLoadGate()
        var loadAsyncCallCount = 0

        await gate.loadIfNeeded {
            loadAsyncCallCount += 1
        }
        await gate.loadIfNeeded {
            loadAsyncCallCount += 1
        }

        XCTAssertEqual(loadAsyncCallCount, 1)
    }

    func testTerminationCoordinatorDefersUntilPendingSaveFlush() async {
        var didFlush = false

        let didReply = await withCheckedContinuation { continuation in
            let reply = PasteBuddyTerminationCoordinator.flushBeforeTerminating({
                didFlush = true
            }, reply: { shouldTerminate in
                continuation.resume(returning: shouldTerminate)
            })

            XCTAssertEqual(reply, .terminateLater)
        }

        XCTAssertTrue(didReply)
        XCTAssertTrue(didFlush)
    }

    func testShelfDirectPasteWaitsOneMainActorTurnAfterImmediateDismissal() async {
        var events: [String] = []

        await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
            dismiss: {
                events.append("dismiss")
                Task { @MainActor in
                    events.append("focus-restored")
                }
            },
            operation: {
                events.append("paste")
            }
        )

        XCTAssertEqual(events, ["dismiss", "focus-restored", "paste"])
    }

    func testPanelHotKeyMatcherRequiresCommandShiftV() {
        XCTAssertTrue(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift]
            )
        )

        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_B),
                flags: [.maskCommand, .maskShift]
            )
        )
        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand]
            )
        )
        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift, .maskAlternate]
            )
        )
        XCTAssertFalse(
            PasteBuddyPanelHotKeyMatcher.matches(
                keyCode: Int64(kVK_ANSI_V),
                flags: [.maskCommand, .maskShift, .maskControl]
            )
        )
    }

    func testDiagnosticsRecorderCapturesHotKeyEventsForTesting() {
        var events: [PasteBuddyDiagnosticEvent] = []
        PasteBuddyDiagnostics.installTestSink { event in
            events.append(event)
        }
        defer { PasteBuddyDiagnostics.removeTestSink() }

        PasteBuddyDiagnostics.record(.hotKey, "carbonRegistered", detail: "status=0")

        XCTAssertEqual(
            events,
            [
                PasteBuddyDiagnosticEvent(
                    category: .hotKey,
                    name: "carbonRegistered",
                    detail: "status=0"
                )
            ]
        )
    }

    func testDiagnosticsRecorderCapturesAccessibilityTrustChecksForTesting() {
        var events: [PasteBuddyDiagnosticEvent] = []
        PasteBuddyDiagnostics.installTestSink { event in
            events.append(event)
        }
        defer { PasteBuddyDiagnostics.removeTestSink() }

        PasteBuddyDiagnostics.recordAccessibilityTrust(
            .shelf,
            "accessibilityTrustCheckedBeforeShelfToggle",
            isTrusted: true
        )

        XCTAssertEqual(
            events,
            [
                PasteBuddyDiagnosticEvent(
                    category: .shelf,
                    name: "accessibilityTrustCheckedBeforeShelfToggle",
                    detail: "trusted=true"
                )
            ]
        )
    }

    func testShelfGlassSurfacesUseNativeTintWithoutStackedBase() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift")
        let bottomSheetStart = try XCTUnwrap(source.range(of: "func pasteBuddyBottomSheetSurface"))
        let glassSurfaceStart = try XCTUnwrap(source.range(of: "func pasteBuddyGlassSurface"))
        let bottomSheetSurface = String(source[bottomSheetStart.lowerBound..<glassSurfaceStart.lowerBound])
        let nativeGlassStart = try XCTUnwrap(bottomSheetSurface.range(of: "if #available(macOS 26.0, *)"))
        let fallbackStart = try XCTUnwrap(bottomSheetSurface.range(of: "} else {"))
        let nativeGlassBranch = String(bottomSheetSurface[nativeGlassStart.lowerBound..<fallbackStart.lowerBound])
        let glassSurface = String(source[glassSurfaceStart.lowerBound...])
        let smallNativeStart = try XCTUnwrap(glassSurface.range(of: "if #available(macOS 26.0, *)"))
        let smallFallbackStart = try XCTUnwrap(glassSurface.range(of: "} else {"))
        let smallNativeGlassBranch = String(glassSurface[smallNativeStart.lowerBound..<smallFallbackStart.lowerBound])

        XCTAssertFalse(source.contains("PasteBuddyGlassContainer"))
        XCTAssertFalse(source.contains("@State private var glassTintOpacity"))
        XCTAssertFalse(source.contains("ShelfGlassOpacityControl"))
        XCTAssertFalse(source.contains("Slider(value: $opacity"))
        XCTAssertFalse(source.contains("glassTintOpacity: glassTintOpacity"))
        XCTAssertTrue(source.contains("static let defaultTintOpacity = 0.30"))
        XCTAssertTrue(source.contains("static let detailSuppressionOpacity = 0.28"))
        XCTAssertTrue(source.contains("glassTintOpacity: Double = ClipboardShelfGlass.defaultTintOpacity"))
        XCTAssertTrue(source.contains("let tintOpacity = min(max(glassTintOpacity, 0), 1)"))
        XCTAssertTrue(nativeGlassBranch.contains(".fill(.thickMaterial)"))
        XCTAssertTrue(nativeGlassBranch.contains("ClipboardShelfGlass.detailSuppressionOpacity"))
        XCTAssertTrue(nativeGlassBranch.contains(".glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tintOpacity)), in: shape)"))
        XCTAssertFalse(nativeGlassBranch.contains(".background"))
        XCTAssertFalse(bottomSheetSurface.contains("opacity(0.82)"))
        XCTAssertTrue(smallNativeGlassBranch.contains("Glass.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tintOpacity)).interactive()"))
        XCTAssertFalse(smallNativeGlassBranch.contains(".background"))
    }

    func testPanelHotKeyTriggerGateRecordsSourceAndDeduplicates() {
        var events: [PasteBuddyDiagnosticEvent] = []
        PasteBuddyDiagnostics.installTestSink { event in
            events.append(event)
        }
        defer { PasteBuddyDiagnostics.removeTestSink() }

        var gate = PasteBuddyPanelHotKeyTriggerGate()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(gate.shouldTrigger(source: .eventTap, now: now))
        XCTAssertFalse(gate.shouldTrigger(source: .carbon, now: now.addingTimeInterval(0.10)))
        XCTAssertTrue(gate.shouldTrigger(source: .carbon, now: now.addingTimeInterval(0.30)))

        XCTAssertEqual(
            events.map { "\($0.category.rawValue).\($0.name):\($0.detail ?? "")" },
            [
                "hotKey.pressed:source=eventTap",
                "hotKey.ignoredDuplicate:source=carbon",
                "hotKey.pressed:source=carbon"
            ]
        )
    }

    func testShelfDirectPasteCoordinatorRecordsDiagnosticBoundaries() async {
        var events: [PasteBuddyDiagnosticEvent] = []
        PasteBuddyDiagnostics.installTestSink { event in
            events.append(event)
        }
        defer { PasteBuddyDiagnostics.removeTestSink() }

        _ = await ClipboardShelfDirectPasteCoordinator.runAfterImmediateDismissal(
            dismiss: {},
            operation: {
                "done"
            }
        )

        XCTAssertEqual(
            events.map { "\($0.category.rawValue).\($0.name)" },
            [
                "directPaste.dismissImmediate",
                "directPaste.operationStarted",
                "directPaste.operationFinished"
            ]
        )
    }

    func testAppIconThemeColorUsesLargestChromaticRegion() {
        let width = 40
        let height = 40
        let image = makeTestImage(width: width, height: height) { x, _ in
            x < 30
                ? (red: 255, green: 59, blue: 48, alpha: 255)
                : (red: 0, green: 122, blue: 255, alpha: 255)
        }

        let dominantColor = AppIconThemeColorResolver.dominantColor(in: image, sampleSize: 40)
        let rgbColor = dominantColor?.usingColorSpace(.deviceRGB)

        XCTAssertNotNil(rgbColor)
        XCTAssertGreaterThan(rgbColor?.redComponent ?? 0, rgbColor?.blueComponent ?? 1)
        XCTAssertGreaterThan(rgbColor?.redComponent ?? 0, rgbColor?.greenComponent ?? 1)
    }

    func testAppIconThemeColorPrefersSaturatedBrandMarkOverMutedBackground() {
        let width = 40
        let height = 40
        let image = makeTestImage(width: width, height: height) { x, y in
            let isBrandMark = (12..<28).contains(x) && (12..<28).contains(y)
            return isBrandMark
                ? (red: 0, green: 122, blue: 255, alpha: 255)
                : (red: 130, green: 150, blue: 115, alpha: 255)
        }

        let dominantColor = AppIconThemeColorResolver.dominantColor(in: image, sampleSize: 40)
        let rgbColor = dominantColor?.usingColorSpace(.deviceRGB)

        XCTAssertNotNil(rgbColor)
        XCTAssertGreaterThan(rgbColor?.blueComponent ?? 0, rgbColor?.redComponent ?? 1)
        XCTAssertGreaterThan(rgbColor?.blueComponent ?? 0, rgbColor?.greenComponent ?? 1)
    }

    private func makeTestImage(
        width: Int,
        height: Int,
        pixel: (_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
    ) -> NSImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let color = pixel(x, y)
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
                pixels[offset + 3] = color.alpha
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func sourceFileContents(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(FileManager.default.currentDirectoryPath)")
    }
}
