import AppKit
import XCTest

@testable import capcap

/// Exercises the real capture/match/compose/preview pipeline with supplied
/// source frames. ScreenCaptureKit and system permissions are not exercised.
@MainActor
final class ScrollCapturerTests: XCTestCase {
    func testFirstFramePublishesPreviewWithoutWaitingForAScroll() async throws {
        let document = DocumentFixture()
        let sequence = FrameSequence([document.frame(offset: 0)])
        let previewReceived = expectation(description: "Initial frame preview")
        var preview: NSImage?
        let capturer = try makeCapturer(sequence: sequence) { image in
            preview = image
            previewReceived.fulfill()
        }

        await fulfillment(of: [previewReceived], timeout: 3)

        let image = try XCTUnwrap(preview)
        assertThumbnail(image, pointSize: NSSize(width: 120, height: 180))
        // Keep the capturer alive until its asynchronously delivered callback.
        capturer.onPreviewUpdated = nil
    }

    func testStitchesSourceDocumentWithOneHeaderAndFooterAndKeepsLastThreePixels() async throws {
        let document = DocumentFixture()
        let offsets = [0, 80, 157, 160]
        let sequence = FrameSequence(offsets.map { document.frame(offset: $0) })
        let capturer = try makeCapturer(sequence: sequence)

        for _ in offsets.dropFirst() {
            assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false))
        }
        let result = try await finish(capturer)

        XCTAssertFalse(result.isIncomplete)
        let image = try XCTUnwrap(result.image)
        let expected = document.expectedImage(lastOffset: 160)
        assertPixels(image, equalTo: expected)
        // Two backing pixels per point makes a final 3 px movement observable.
        XCTAssertEqual(image.size, NSSize(width: 120, height: 260))
    }

    func testUnmatchedInputPreservesLastSuccessfulImageAndReportsIncomplete() async throws {
        let document = DocumentFixture()
        let sequence = FrameSequence([0, 80, 790].map { document.frame(offset: $0) })
        let capturer = try makeCapturer(sequence: sequence)

        assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false))
        guard case .retry = capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false) else {
            return XCTFail("A disjoint source frame must be rejected")
        }
        let result = try await finish(capturer)

        XCTAssertTrue(result.isIncomplete)
        assertPixels(try XCTUnwrap(result.image), equalTo: document.expectedImage(lastOffset: 80))
    }

    func testSparseNewTailPreservesTheLastImageAndReportsIncomplete() async throws {
        let blank = DocumentFixture.sparseTail(visible: false)
        let tail = DocumentFixture.sparseTail(visible: true)
        let sequence = FrameSequence([blank, tail])
        let capturer = try makeCapturer(sequence: sequence)

        guard case .retry = capturer.captureSynchronously(expectedShiftPoints: 10, waitsForSettledFrame: false) else {
            return XCTFail("A small new mark on a blank page must remain unresolved")
        }
        let result = try await finish(capturer)

        XCTAssertTrue(result.isIncomplete)
        assertPixels(try XCTUnwrap(result.image), equalTo: try XCTUnwrap(blank.cgImagePreservingBacking()))
    }

    func testTerminalStreamFailureStopsCaptureAndCannotBeClearedByAnUnchangedFinalStill() async throws {
        let document = DocumentFixture()
        let initial = document.frame(offset: 0)
        let source = BufferedFrameSource([
            .frames([try streamFrame(initial, sequence: 1)]),
            .failed
        ])
        let capturer = try makeStreamCapturer(source: source, finalImage: initial)

        for _ in 0..<2 {
            guard case .captureFailed = capturer.captureSynchronously(expectedShiftPoints: 0) else {
                return XCTFail("A failed stream must end capture instead of polling forever")
            }
        }
        let result = try await finish(capturer)

        XCTAssertEqual(source.snapshotCount, 2)
        XCTAssertTrue(source.stopped)
        XCTAssertTrue(result.isIncomplete)
        assertPixels(try XCTUnwrap(result.image), equalTo: document.expectedImage(lastOffset: 0))
    }

    func testStreamStartupFailureIsTerminalWithoutAnInitialImage() async throws {
        let source = BufferedFrameSource([.failed])
        let capturer = try makeStreamCapturer(source: source, finalImage: nil)

        XCTAssertFalse(capturer.prepareInitialFrameSynchronously())
        guard case .captureFailed = capturer.captureSynchronously(expectedShiftPoints: 0) else {
            return XCTFail("Startup failure must not become an endless temporary capture error")
        }
        let result = try await finish(capturer)

        XCTAssertNil(result.image)
        XCTAssertTrue(result.isIncomplete)
        XCTAssertEqual(source.snapshotCount, 1)
        XCTAssertTrue(source.stopped)
    }

    func testTemporaryStreamUnavailabilityCanRecover() async throws {
        let document = DocumentFixture()
        let initial = document.frame(offset: 0)
        let next = document.frame(offset: 80)
        let source = BufferedFrameSource([
            .frames([try streamFrame(initial, sequence: 1)]),
            .unavailable,
            .frames([try streamFrame(next, sequence: 2)])
        ])
        let capturer = try makeStreamCapturer(source: source, finalImage: next)

        guard case .captureUnavailable = capturer.captureSynchronously(expectedShiftPoints: 0) else {
            return XCTFail("A temporary empty read must remain retryable")
        }
        assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0))
        let result = try await finish(capturer)

        XCTAssertFalse(result.isIncomplete)
        assertPixels(try XCTUnwrap(result.image), equalTo: document.expectedImage(lastOffset: 80))
    }

    func testBufferedIntermediateFrameBridgesAJumpBeyondTheViewport() async throws {
        let document = DocumentFixture()
        let last = document.frame(offset: 400)
        let source = BufferedFrameSource([
            .frames([try streamFrame(document.frame(offset: 0), sequence: 1)]),
            .frames([
                try streamFrame(document.frame(offset: 200), sequence: 2),
                try streamFrame(last, sequence: 3)
            ])
        ])
        let capturer = try makeStreamCapturer(source: source, finalImage: last)

        assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0))
        let result = try await finish(capturer)

        XCTAssertFalse(result.isIncomplete)
        assertPixels(try XCTUnwrap(result.image), equalTo: document.expectedImage(lastOffset: 400))
    }

    func testReverseScrollDoesNotAppendAndCaptureRecoversPastTheAcceptedEnd() async throws {
        let document = DocumentFixture()
        let sequence = FrameSequence([0, 100, 31, 170].map { document.frame(offset: $0) })
        let capturer = try makeCapturer(sequence: sequence)

        assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false))
        guard case .noNewContent = capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false) else {
            return XCTFail("Returning to already captured source rows must not append")
        }
        assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false))
        let result = try await finish(capturer)

        XCTAssertFalse(result.isIncomplete)
        assertPixels(try XCTUnwrap(result.image), equalTo: document.expectedImage(lastOffset: 170))
    }

    func testRoundedViewportCornersDoNotRemainInsideTheStitchedDocument() async throws {
        let document = DocumentFixture()
        let offsets = [0, 96, 192]
        let sequence = FrameSequence(offsets.map {
            document.frame(offset: $0, roundedBottomCorners: true)
        })
        let capturer = try makeCapturer(sequence: sequence)

        for _ in offsets.dropFirst() {
            assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false))
        }
        let result = try await finish(capturer)

        XCTAssertFalse(result.isIncomplete)
        let image = try XCTUnwrap(result.image)
        // The expected source document is unobscured throughout its interior.
        // Only the final viewport's two bottom corners retain their mask.
        let expected = document.expectedImage(lastOffset: 192, roundedBottomCorners: true)
        assertPixels(image, equalTo: expected)
        XCTAssertEqual(image.size, NSSize(width: 120, height: 276))
    }

    func testQueuedPreviewsCoalesceToTheLatestBoundedThumbnailWithoutChangingFinalPixels() async throws {
        let document = DocumentFixture()
        let offsets = [0, 120, 240, 360, 480]
        let sequence = FrameSequence(offsets.map { document.frame(offset: $0) })
        var previews: [NSImage] = []
        let capturer = try makeCapturer(sequence: sequence) { previews.append($0) }
        await drainMainQueue()
        let initialPreview = try XCTUnwrap(previews.first)
        let initialRaster = try XCTUnwrap(initialPreview.cgImagePreservingBacking())
        let initialPixels = DocumentFixture.rgba(initialRaster)
        previews.removeAll()

        // The main actor cannot deliver callbacks during this synchronous
        // burst. Only the newest accepted canvas should occupy its queue slot.
        for _ in offsets.dropFirst() {
            assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false))
        }
        await drainMainQueue()

        XCTAssertEqual(previews.count, 1)
        let latest = try XCTUnwrap(previews.last)
        assertThumbnail(latest, pointSize: NSSize(width: 120, height: 420))
        let thumbnailRaster = try XCTUnwrap(latest.cgImagePreservingBacking())
        XCTAssertEqual(thumbnailRaster.height, 800)
        // Later footer replacement must not mutate a previously delivered
        // thumbnail through the borrowed mutable canvas storage.
        XCTAssertEqual(DocumentFixture.rgba(initialRaster), initialPixels)

        let result = try await finish(capturer)
        XCTAssertFalse(result.isIncomplete)
        let image = try XCTUnwrap(result.image)
        assertPixels(image, equalTo: document.expectedImage(lastOffset: 480))
        XCTAssertEqual(image.size, NSSize(width: 120, height: 420))
    }

    func testClearingPreviewCallbackDiscardsItsPendingDelivery() async throws {
        let document = DocumentFixture()
        let sequence = FrameSequence([0, 80].map { document.frame(offset: $0) })
        var previews: [NSImage] = []
        let capturer = try makeCapturer(sequence: sequence) { previews.append($0) }
        await drainMainQueue()
        previews.removeAll()

        assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false))
        capturer.onPreviewUpdated = nil
        await drainMainQueue()

        XCTAssertTrue(previews.isEmpty)
        let result = try await finish(capturer)
        assertPixels(try XCTUnwrap(result.image), equalTo: document.expectedImage(lastOffset: 80))
    }

    func testFinishingDiscardsPendingPreviewAndStillCapturesTheTailAtFullResolution() async throws {
        let document = DocumentFixture()
        let sequence = FrameSequence([0, 80, 160].map { document.frame(offset: $0) })
        var previews: [NSImage] = []
        let capturer = try makeCapturer(sequence: sequence) { previews.append($0) }
        await drainMainQueue()
        previews.removeAll()

        assertAppended(capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false))
        // Offset 80 has a queued thumbnail; the final sample adds offset 160
        // without generating another UI preview on the way to the final image.
        let result = try await finish(capturer)

        XCTAssertTrue(previews.isEmpty)
        XCTAssertFalse(result.isIncomplete)
        assertPixels(try XCTUnwrap(result.image), equalTo: document.expectedImage(lastOffset: 160))
    }

    private func makeCapturer(
        sequence: FrameSequence,
        onPreviewUpdated: ((NSImage) -> Void)? = nil
    ) throws -> ScrollCapturer {
        ScrollCapturer(
            rect: CGRect(x: 0, y: 0, width: 120, height: 180),
            screen: try XCTUnwrap(NSScreen.screens.first),
            onPreviewUpdated: onPreviewUpdated,
            captureImage: { sequence.next() }
        )
    }

    private func makeStreamCapturer(source: BufferedFrameSource, finalImage: NSImage?) throws -> ScrollCapturer {
        ScrollCapturer(
            rect: CGRect(x: 0, y: 0, width: 120, height: 180),
            screen: try XCTUnwrap(NSScreen.screens.first),
            captureImage: { finalImage },
            frameSource: source
        )
    }

    private func streamFrame(_ image: NSImage, sequence: UInt64) throws -> ScrollFrameStream.Frame {
        let source = try XCTUnwrap(image.cgImagePreservingBacking())
        // The production stream and its final still use the same BGRA layout.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let raster = try XCTUnwrap(context.makeImage())
        return ScrollFrameStream.Frame(sequence: sequence, image: raster, byteCount: raster.bytesPerRow * raster.height)
    }

    private func finish(_ capturer: ScrollCapturer) async throws -> ScrollCapturer.StitchResult {
        let finished = expectation(description: "Capture composition completes")
        var result: ScrollCapturer.StitchResult?
        capturer.stopAndStitch {
            result = $0
            finished.fulfill()
        }
        // Yield the main actor so final completion can run.
        await fulfillment(of: [finished], timeout: 10)
        return try XCTUnwrap(result)
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Pending preview delivery drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
    }

    private func assertThumbnail(
        _ image: NSImage,
        pointSize: NSSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(image.size, pointSize, file: file, line: line)
        guard let raster = image.cgImagePreservingBacking() else {
            return XCTFail("Preview has no raster backing", file: file, line: line)
        }
        XCTAssertGreaterThan(raster.width, 0, file: file, line: line)
        XCTAssertGreaterThan(raster.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(raster.width, 240, file: file, line: line)
        XCTAssertLessThanOrEqual(raster.height, 800, file: file, line: line)
        // Integer thumbnail rounding may differ by at most one source pixel.
        XCTAssertEqual(
            CGFloat(raster.width),
            CGFloat(raster.height) * pointSize.width / pointSize.height,
            accuracy: 1,
            file: file, line: line
        )
    }

    private func assertAppended(
        _ outcome: ScrollCapturer.FrameOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .appended = outcome else {
            return XCTFail("Expected source document rows to be appended", file: file, line: line)
        }
    }

    private func assertPixels(
        _ actual: NSImage,
        equalTo expected: CGImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actualCG = actual.cgImagePreservingBacking() else {
            return XCTFail("Composed image has no raster backing", file: file, line: line)
        }
        XCTAssertEqual(actualCG.width, expected.width, file: file, line: line)
        XCTAssertEqual(actualCG.height, expected.height, file: file, line: line)
        guard actualCG.width == expected.width, actualCG.height == expected.height else { return }
        let actualPixels = DocumentFixture.rgba(actualCG)
        let expectedPixels = DocumentFixture.rgba(expected)
        if let index = actualPixels.indices.first(where: { actualPixels[$0] != expectedPixels[$0] }) {
            let pixel = index / 4
            XCTFail(
                "Pixel (\(pixel % expected.width), \(pixel / expected.width)), channel \(index % 4): " +
                "expected \(expectedPixels[index]), got \(actualPixels[index])",
                file: file, line: line
            )
        }
    }

    private final class FrameSequence {
        private let frames: [NSImage]
        private var index = 0
        private let lock = NSLock()

        init(_ frames: [NSImage]) { self.frames = frames }

        func next() -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            guard !frames.isEmpty else { return nil }
            let image = frames[min(index, frames.count - 1)]
            index += 1
            return image
        }
    }

    private final class BufferedFrameSource: ScrollFrameSource {
        private let snapshots: [ScrollFrameStream.Snapshot]
        private(set) var snapshotCount = 0
        private(set) var stopped = false

        init(_ snapshots: [ScrollFrameStream.Snapshot]) { self.snapshots = snapshots }

        func snapshot(after consumedSequence: UInt64, timeout: TimeInterval, waitsForNewFrame: Bool) -> ScrollFrameStream.Snapshot {
            let snapshot = snapshots[min(snapshotCount, snapshots.count - 1)]
            snapshotCount += 1
            return snapshot
        }

        func discard(through consumedSequence: UInt64) {}
        func stop() { stopped = true }
    }

    private struct DocumentFixture {
        private let document: CGImage
        private let header: CGImage
        private let footer: CGImage
        private let visibleDocumentRows = 308

        static func sparseTail(visible: Bool) -> NSImage {
            let image = image(height: 1000) { x, y in
                visible && (100..<112).contains(x) && (990..<1000).contains(y) ? 0 : 255
            }
            return NSImage(cgImage: image, size: NSSize(width: 120, height: 500))
        }

        init() {
            document = Self.image(height: 1600) { x, y in
                let row = y / 29
                let rowY = y % 29
                var value = 247
                if rowY == 27 { value = 215 }
                if (5..<17).contains(rowY), (14..<222).contains(x) {
                    let character = (x - 14) / 9
                    let characterX = (x - 14) % 9
                    let bits = UInt64(row + 1) &* 6_364_136_223_846_793_005 &+
                        UInt64(character + 3) &* 1_442_695_040_888_963_407
                    if characterX < 6, (bits >> UInt64((rowY + characterX) % 37)) & 1 == 1 {
                        value = 38 + Int(bits % 58)
                    }
                }
                return value
            }
            header = Self.image(height: 38) { x, y in
                y == 37 ? 65 : ((19..<210).contains(x) && (9..<24).contains(y) ? 105 : 224)
            }
            // The fixed footer contains white padding above its black border.
            footer = Self.image(height: 14) { _, y in y < 10 ? 247 : 18 }
        }

        func frame(offset: Int, roundedBottomCorners: Bool = false) -> NSImage {
            let body = document.cropping(to: CGRect(x: 0, y: offset, width: 240, height: visibleDocumentRows))!
            let unmasked = Self.stack([header, body, footer])
            let image = roundedBottomCorners ? Self.maskBottomCorners(unmasked) : unmasked
            return NSImage(cgImage: image, size: NSSize(width: 120, height: 180))
        }

        func expectedImage(lastOffset: Int, roundedBottomCorners: Bool = false) -> CGImage {
            // The expected result is the original document prefix surrounded
            // by its fixed chrome, independent of estimated seams or shifts.
            let body = document.cropping(to: CGRect(
                x: 0, y: 0, width: 240, height: visibleDocumentRows + lastOffset
            ))!
            let unmasked = Self.stack([header, body, footer])
            return roundedBottomCorners ? Self.maskBottomCorners(unmasked) : unmasked
        }

        private static func maskBottomCorners(_ image: CGImage) -> CGImage {
            var pixels = rgba(image)
            // A container clips the sides of its last 48 px while its center
            // still displays moving document rows. This is not a full footer.
            for y in (image.height - 48)..<image.height {
                let depth = y - (image.height - 48) + 1
                let cornerWidth = depth * 20 / 48
                for x in 0..<image.width where x < cornerWidth || x >= image.width - cornerWidth {
                    let start = (y * image.width + x) * 4
                    pixels[start] = 3
                    pixels[start + 1] = 3
                    pixels[start + 2] = 3
                }
            }
            return raster(pixels, height: image.height)
        }

        private static func image(height: Int, value: (Int, Int) -> Int) -> CGImage {
            var pixels = [UInt8](repeating: 255, count: 240 * height * 4)
            for y in 0..<height {
                for x in 0..<240 {
                    let start = (y * 240 + x) * 4
                    let gray = UInt8(value(x, y))
                    pixels[start] = gray
                    pixels[start + 1] = gray
                    pixels[start + 2] = gray
                }
            }
            return raster(pixels, height: height)
        }

        private static func stack(_ images: [CGImage]) -> CGImage {
            raster(images.flatMap { rgba($0) }, height: images.reduce(0) { $0 + $1.height })
        }

        private static func raster(_ pixels: [UInt8], height: Int) -> CGImage {
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            return CGImage(
                width: 240, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )!
        }

        static func rgba(_ image: CGImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            pixels.withUnsafeMutableBytes { storage in
                let context = CGContext(
                    data: storage.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return pixels
        }
    }
}
