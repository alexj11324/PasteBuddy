import CoreGraphics
import PasteBuddyCore
import XCTest
@testable import PasteBuddy

final class ScreenCaptureModelsTests: XCTestCase {
    func testSelectionGeometrySupportsSquareDragPixelMoveAndManualDimensions() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let square = CaptureSelectionGeometry.selection(
            from: CGPoint(x: 20, y: 30),
            to: CGPoint(x: 140, y: 90),
            in: bounds,
            aspectLock: .square
        )
        XCTAssertEqual(square, CGRect(x: 20, y: 30, width: 60, height: 60))

        let moved = CaptureSelectionGeometry.moved(square, dx: -50, dy: 200, in: bounds)
        XCTAssertEqual(moved, CGRect(x: 0, y: 140, width: 60, height: 60))

        let resized = CaptureSelectionGeometry.resized(
            moved,
            width: 100,
            height: 40,
            in: bounds,
            aspectLock: .ratio(2)
        )
        XCTAssertEqual(resized.size, CGSize(width: 100, height: 50))
        XCTAssertTrue(bounds.contains(resized))

        let interior = resized.offsetBy(dx: 50, dy: 0)
        let grownLeft = CaptureSelectionGeometry.resizedEdge(
            interior,
            dx: -1,
            dy: 0,
            grow: true,
            in: bounds
        )
        XCTAssertEqual(grownLeft.minX, interior.minX - 1)
        XCTAssertEqual(grownLeft.width, interior.width + 1)
        let shrunkBottom = CaptureSelectionGeometry.resizedEdge(
            grownLeft,
            dx: 0,
            dy: 1,
            grow: false,
            in: bounds
        )
        XCTAssertEqual(shrunkBottom.height, grownLeft.height - 1)
    }

    func testVerticalOverlapMatcherFindsIncrementalScroll() {
        let source = raster(width: 12, height: 90) { x, y in
            UInt8(truncatingIfNeeded: y * y * 7 + x * 19 + y * x * 3)
        }
        let previous = slice(source, x: 0, y: 0, width: 12, height: 50)
        let current = slice(source, x: 0, y: 30, width: 12, height: 50)

        guard case .matched(let overlap, let score) = LongScreenshotOverlapMatcher().match(
            previous: previous,
            current: current,
            direction: .vertical
        ) else {
            return XCTFail("Expected a deterministic vertical overlap")
        }
        XCTAssertEqual(overlap, 20)
        XCTAssertEqual(score, 0, accuracy: 0.001)
    }

    func testHorizontalOverlapMatcherFindsIncrementalScroll() {
        let source = raster(width: 100, height: 10) { x, y in
            UInt8(truncatingIfNeeded: x * x * 5 + y * 23 + x * y * 7)
        }
        let previous = slice(source, x: 0, y: 0, width: 60, height: 10)
        let current = slice(source, x: 35, y: 0, width: 60, height: 10)

        guard case .matched(let overlap, _) = LongScreenshotOverlapMatcher().match(
            previous: previous,
            current: current,
            direction: .horizontal
        ) else {
            return XCTFail("Expected a deterministic horizontal overlap")
        }
        XCTAssertEqual(overlap, 25)
    }

    func testMatcherDistinguishesNoMovementAmbiguousAndNoMatch() {
        let unique = raster(width: 12, height: 40) { x, y in
            UInt8(truncatingIfNeeded: y * 17 + x * 31)
        }
        XCTAssertEqual(
            LongScreenshotOverlapMatcher().match(
                previous: unique,
                current: unique,
                direction: .vertical
            ),
            .noMovement
        )

        let repetitive = raster(width: 12, height: 40) { _, y in
            UInt8(y.isMultiple(of: 2) ? 20 : 220)
        }
        let shiftedRepetitive = raster(width: 12, height: 40) { _, y in
            UInt8(y.isMultiple(of: 2) ? 220 : 20)
        }
        if case .ambiguous = LongScreenshotOverlapMatcher().match(
            previous: repetitive,
            current: shiftedRepetitive,
            direction: .vertical
        ) {
            // Expected.
        } else {
            XCTFail("Repetitive content must fail as ambiguous")
        }

        let unrelated = raster(width: 12, height: 40) { x, y in
            UInt8(truncatingIfNeeded: 255 - y * 9 - x * 13)
        }
        if case .noMatch = LongScreenshotOverlapMatcher().match(
            previous: unique,
            current: unrelated,
            direction: .vertical
        ) {
            // Expected.
        } else {
            XCTFail("Unrelated dynamic content must fail visibly")
        }
    }

    func testLongScreenshotLimitsFailBeforeUnsafeAllocation() {
        let limits = LongScreenshotLimits.default

        XCTAssertTrue(limits.permits(width: 2_000, height: 20_000, frameCount: 40))
        XCTAssertFalse(limits.permits(width: 4_000, height: 20_000, frameCount: 40))
        XCTAssertFalse(limits.permits(width: 1, height: 80_001, frameCount: 40))
        XCTAssertFalse(limits.permits(width: 1_000, height: 1_000, frameCount: 501))
        XCTAssertTrue(limits.permitsStoredPixelCount(96_000_000))
        XCTAssertFalse(limits.permitsStoredPixelCount(96_000_001))
    }

    func testDisplayGeometryConvertsBetweenAppKitAndQuartzCoordinates() {
        let geometry = CaptureDisplayGeometry(
            appKitFrame: CGRect(x: -1_440, y: 100, width: 1_440, height: 900),
            quartzFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
        )
        let appKitRect = CGRect(x: -1_200, y: 250, width: 400, height: 300)
        let quartzRect = geometry.quartzRect(fromAppKit: appKitRect)

        XCTAssertEqual(quartzRect, CGRect(x: -1_200, y: 450, width: 400, height: 300))
        XCTAssertEqual(geometry.appKitRect(fromQuartz: quartzRect), appKitRect)
    }

    func testLongScreenshotAccumulatorStitchesAndCropsWithoutLoadingPastLimit() throws {
        let source = raster(width: 16, height: 90) { x, y in
            UInt8(truncatingIfNeeded: y * y * 7 + x * 19 + y * x * 3)
        }
        let firstRaster = slice(source, x: 0, y: 0, width: 16, height: 50)
        let secondRaster = slice(source, x: 0, y: 30, width: 16, height: 50)
        var accumulator = LongScreenshotAccumulator(direction: .vertical)

        _ = try accumulator.append(image(from: firstRaster))
        guard case .matched(let overlap, _) = try accumulator.append(image(from: secondRaster)) else {
            return XCTFail("Expected second frame to stitch")
        }
        XCTAssertEqual(overlap, 20)
        XCTAssertEqual(accumulator.width, 16)
        XCTAssertEqual(accumulator.height, 80)
        XCTAssertEqual(accumulator.storedPixelCount, 1_600)

        let rendered = try accumulator.renderedImage(leadingCrop: 3, trailingCrop: 7)
        XCTAssertEqual(rendered.width, 16)
        XCTAssertEqual(rendered.height, 70)
    }

    func testHorizontalAccumulatorStitchesAndCropsInDisplayOrder() throws {
        let source = raster(width: 100, height: 16) { x, y in
            UInt8(truncatingIfNeeded: x * x * 5 + y * 23 + x * y * 7)
        }
        let firstRaster = slice(source, x: 0, y: 0, width: 60, height: 16)
        let secondRaster = slice(source, x: 35, y: 0, width: 60, height: 16)
        var accumulator = LongScreenshotAccumulator(direction: .horizontal)

        _ = try accumulator.append(image(from: firstRaster))
        guard case .matched(let overlap, _) = try accumulator.append(image(from: secondRaster)) else {
            return XCTFail("Expected second horizontal frame to stitch")
        }
        XCTAssertEqual(overlap, 25)
        XCTAssertEqual(accumulator.width, 95)
        XCTAssertEqual(accumulator.height, 16)

        let rendered = try accumulator.renderedImage(leadingCrop: 4, trailingCrop: 6)
        XCTAssertEqual(rendered.width, 85)
        XCTAssertEqual(rendered.height, 16)
    }

    func testScreenCaptureErrorsAreVisibleAndEmptyRegionsFailDeterministically() async {
        XCTAssertFalse(ScreenCaptureServiceError.permissionRequired.localizedDescription.isEmpty)
        XCTAssertFalse(ScreenCaptureServiceError.longCaptureLimitReached.localizedDescription.isEmpty)
        do {
            _ = try await ScreenCaptureService().capture(
                quartzRect: .zero,
                showsCursor: false
            )
            XCTFail("Expected an empty capture region to fail")
        } catch let error as ScreenCaptureServiceError {
            guard case .emptyRegion = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCapturedImageUsesExistingHistoryStoreAndImagePayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteBuddyCaptureTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PasteBuddyStore(
            diskStore: EncryptedSnapshotStore.defaultStore(in: directory)
        )
        store.toggleOCR()
        let raster = raster(width: 12, height: 12) { x, y in
            UInt8(truncatingIfNeeded: x * 17 + y * 23)
        }

        let item = try CapturedImageHistoryWriter(store: store).storeImage(
            image(from: raster),
            titleKey: "label.screenshot"
        )

        XCTAssertEqual(store.snapshot.items.first?.id, item.id)
        XCTAssertEqual(store.snapshot.items.first?.contentType, .image)
        XCTAssertNotNil(store.snapshot.items.first?.payload.imageData)
    }

    private func raster(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> UInt8
    ) -> LongScreenshotRaster {
        LongScreenshotRaster(
            width: width,
            height: height,
            grayscalePixels: (0..<height).flatMap { y in
                (0..<width).map { x in pixel(x, y) }
            }
        )
    }

    private func slice(
        _ source: LongScreenshotRaster,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> LongScreenshotRaster {
        raster(width: width, height: height) { sliceX, sliceY in
            source[x + sliceX, y + sliceY]
        }
    }

    private func image(from raster: LongScreenshotRaster) throws -> CGImage {
        var pixels = raster.grayscalePixels.flatMap { value in
            [value, value, value, UInt8.max]
        }
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: raster.width,
                height: raster.height,
                bitsPerComponent: 8,
                bytesPerRow: raster.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
    }
}
