import AppKit
import XCTest

@testable import capcap

final class ScrollImageStitcherTests: XCTestCase {
    func testTallFixedHeaderAndOnePixelFooterAppearOnlyOnceAtRetinaResolution() throws {
        let stitcher = ScrollImageStitcher()
        for offset in [0, 37, 65, 66] {
            XCTAssertEqual(stitcher.append(try viewport(offset: offset)), .appended)
        }
        let result = try XCTUnwrap(stitcher.takeImage())
        let expected = try viewport(offset: 0, height: 306)
        XCTAssertEqual(result.size, NSSize(width: 64, height: 153))
        XCTAssertEqual(try pixels(result), try pixels(expected))
    }

    func testUnmatchedFrameDoesNotReplaceTheAnchorOrLeaveAGap() throws {
        let stitcher = ScrollImageStitcher()
        XCTAssertEqual(stitcher.append(try viewport(offset: 0)), .appended)
        XCTAssertEqual(stitcher.append(try viewport(offset: 900), expectedShiftPoints: 12), .unmatched)
        XCTAssertEqual(stitcher.append(try viewport(offset: 23)), .appended)
        XCTAssertEqual(stitcher.append(try viewport(offset: 23)), .noNewContent)
        XCTAssertEqual(stitcher.append(try viewport(offset: 0)), .noNewContent)
        XCTAssertEqual(try pixels(XCTUnwrap(stitcher.takeImage())), try pixels(viewport(offset: 0, height: 263)))
    }

    func testRepeatedRowsDoNotUseTheRequestedWheelDistanceToBreakATie() throws {
        let stitcher = ScrollImageStitcher()
        XCTAssertEqual(stitcher.append(try viewport(offset: 0, repeatRows: 16)), .appended)
        XCTAssertEqual(stitcher.append(try viewport(offset: 5, repeatRows: 16), expectedShiftPoints: 2.5), .unmatched)
    }

    func testShortNarrowSelectionKeepsOnePixelOfNewContent() throws {
        let stitcher = ScrollImageStitcher()
        for offset in [0, 1] {
            XCTAssertEqual(stitcher.append(try viewport(offset: offset, width: 17, height: 24, header: 6)), .appended)
        }
        let expected = try viewport(offset: 0, width: 17, height: 25, header: 6)
        XCTAssertEqual(try pixels(XCTUnwrap(stitcher.takeImage())), try pixels(expected))
    }

    /// Changing the height extends only the document body, so a taller image
    /// also supplies the exact reference pixels for the finished screenshot.
    private func viewport(
        offset: Int, width: Int = 128, height: Int = 240, header: Int = 104, repeatRows: Int? = nil
    ) throws -> NSImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<(height - 1) {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if y < header {
                    let shade: UInt8 = (x / 8 + y / 6).isMultiple(of: 2) ? 70 : 200
                    bytes[index] = shade
                    bytes[index + 1] = shade
                    bytes[index + 2] = shade
                } else {
                    let row = y - header + offset
                    let documentRow = repeatRows.map { row % $0 } ?? row
                    var value = UInt64(documentRow * width + x + 1) &* 6_364_136_223_846_793_005
                    value ^= value >> 17
                    value = value &* 1_442_695_040_888_963_407
                    bytes[index] = UInt8(truncatingIfNeeded: value >> 48)
                    bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 32)
                    bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 24)
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let raster = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return NSImage(cgImage: raster, size: NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2))
    }

    private func pixels(_ image: NSImage) throws -> Data {
        let raster = try XCTUnwrap(image.cgImagePreservingBacking())
        let context = try XCTUnwrap(CGContext(
            data: nil, width: raster.width, height: raster.height, bitsPerComponent: 8, bytesPerRow: raster.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * raster.height)
    }
}

extension ScrollImageStitcherTests {
    func testManualScrollWithVideoCoveringThirtyPercentOfViewport() throws {
        try assertStitchedVideoPage(videoHeight: 180, expectedStepPoints: 0)
    }

    func testAutomaticScrollWithVideoCoveringHalfOfViewport() throws {
        try assertStitchedVideoPage(videoHeight: 300, expectedStepPoints: 20)
    }

    func testPlayingVideoOnStillPageAddsNoContent() throws {
        let document = ScrollDocument(videoRows: [150..<330])
        let stitcher = ScrollImageStitcher()
        XCTAssertEqual(stitcher.append(try document.image()), .appended)
        for frame in 1...2 {
            XCTAssertEqual(stitcher.append(try document.image(frame: frame)), .noNewContent)
        }
    }

    func testBlinkingCaretOnStillPageAddsNoContent() throws {
        let document = ScrollDocument(caret: true)
        let stitcher = ScrollImageStitcher()
        XCTAssertEqual(stitcher.append(try document.image(offset: 30)), .appended)
        XCTAssertEqual(stitcher.append(try document.image(offset: 30, frame: 1)), .noNewContent)
    }

    func testTallFixedHeaderDoesNotHideReplacementOfPageBody() throws {
        let stitcher = ScrollImageStitcher()
        XCTAssertEqual(stitcher.append(try ScrollDocument(headerHeight: 270).image()), .appended)
        XCTAssertEqual(stitcher.append(try ScrollDocument(headerHeight: 270, textSeed: 3).image()), .unmatched)
    }

    func testRepeatedListWithVideoNeverAlignsAtAnAliasedShift() throws {
        let document = ScrollDocument(videoRows: [200..<380], repeatRows: 72)
        let before = try XCTUnwrap(document.image().cgImagePreservingBacking())
        // The period makes 10 and 82 both align list rows. A full-period
        // scroll also leaves the visible text in exactly the same place.
        for shift in [10, 72] {
            let after = try XCTUnwrap(document.image(offset: shift, frame: 1).cgImagePreservingBacking())
            let match = ScrollFrameMatcher().match(previous: before, current: after, expectedShift: CGFloat(shift))
            if case let .aligned(alignment) = match {
                XCTAssertEqual(alignment.shift, shift)
            }
        }
    }

    func testReplacingPageWithoutAHeaderIsUnmatched() throws {
        let stitcher = ScrollImageStitcher()
        XCTAssertEqual(stitcher.append(try ScrollDocument(headerHeight: 0).image()), .appended)
        XCTAssertEqual(stitcher.append(try ScrollDocument(headerHeight: 0, textSeed: 99).image()), .unmatched)
    }

    func testSharpPanningVideoDoesNotDetermineThePageShift() throws {
        try assertPanningVideoScroll(period: 40, allowsUnmatched: true)
    }

    func testSoftPanningVideoStillFindsThePageShift() throws {
        try assertPanningVideoScroll(period: 58, allowsUnmatched: false)
    }

    func testNarrowStillBandBetweenTwoVideosAppendsBothScrollSteps() throws {
        let document = ScrollDocument(videoRows: [0..<200, 330..<1200], videoColumns: 30..<270)
        let stitcher = ScrollImageStitcher()
        let anchorOffset = 60
        XCTAssertEqual(stitcher.append(try document.image(offset: anchorOffset)), .appended)

        for (index, offset) in [100, 140].enumerated() {
            let image = try document.image(offset: offset, frame: index + 1)
            let outcome = stitcher.append(image, expectedShiftPoints: 20)
            XCTAssertEqual(outcome, .appended, "At document offset \(offset)")
            guard outcome == .appended else { continue }
            let preview = try XCTUnwrap(stitcher.thumbnail())
            XCTAssertEqual(preview.size.height, CGFloat(document.height + offset - anchorOffset) / 2)
        }
    }

    private func assertPanningVideoScroll(
        period: Double, allowsUnmatched: Bool, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let step = 40
        // Leave visible text above and below the video throughout the sequence.
        let videoTop = 190
        for videoHeight in [240, 330] {
            let document = ScrollDocument(videoRows: [videoTop..<(videoTop + videoHeight)], panningPeriod: period)
            var previous = try document.image()
            for frame in 1...4 {
                let current = try document.image(offset: step * frame, frame: frame)
                // Check adjacent frames even when a sharp video prevents the previous pair from matching.
                let stitcher = ScrollImageStitcher()
                XCTAssertEqual(stitcher.append(previous), .appended, file: file, line: line)
                let outcome = stitcher.append(current, expectedShiftPoints: CGFloat(step) / 2)
                previous = current

                if allowsUnmatched, outcome == .unmatched { continue }
                let context = "\(videoHeight * 100 / document.height)% video at step \(frame)"
                XCTAssertEqual(outcome, .appended, context, file: file, line: line)
                guard outcome == .appended else { continue }
                let stitched = try XCTUnwrap(stitcher.takeImage(), file: file, line: line)
                XCTAssertEqual(stitched.size.height, CGFloat(document.height + step) / 2, context, file: file, line: line)
            }
        }
    }

    private func assertStitchedVideoPage(
        videoHeight: Int, expectedStepPoints: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let videoRows = 210..<(210 + videoHeight)
        let document = ScrollDocument(videoRows: [videoRows])
        let step = 40
        let stepCount = 5
        let stitcher = ScrollImageStitcher()
        XCTAssertEqual(stitcher.append(try document.image()), .appended, file: file, line: line)
        for frame in 1...stepCount {
            let offset = frame * step
            let image = try document.image(offset: offset, frame: frame)
            XCTAssertEqual(
                stitcher.append(image, expectedShiftPoints: expectedStepPoints), .appended,
                "At scroll step \(frame)", file: file, line: line
            )
            let preview = try XCTUnwrap(stitcher.thumbnail(), file: file, line: line)
            XCTAssertEqual(
                preview.size.height, CGFloat(document.height + offset) / 2,
                "At scroll step \(frame)", file: file, line: line
            )
        }

        let still = ScrollDocument(height: document.height + step * stepCount, headerHeight: document.headerHeight)
        let result = try XCTUnwrap(stitcher.takeImage(), file: file, line: line)
        let reference = try still.image()
        XCTAssertEqual(result.size, reference.size, file: file, line: line)
        let actual = try pixels(result)
        let expected = try pixels(reference)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        guard actual.count == expected.count else { return }

        let stride = document.width * 4
        let firstMismatch = (0..<still.height).first { y in
            guard !videoRows.contains(y - document.headerHeight) else { return false }
            let bytes = (y * stride)..<((y + 1) * stride)
            return actual[bytes] != expected[bytes]
        }
        XCTAssertNil(firstMismatch, "First differing row outside the video", file: file, line: line)
    }
}

final class ScrollMatcherRegressionTests: XCTestCase {
    func testRepeatedRowsCannotEstablishAnUnambiguousScroll() throws {
        let document = ScrollDocument(headerHeight: 180, repeatRows: 72)
        let previous = try XCTUnwrap(document.image().cgImagePreservingBacking())
        let current = try XCTUnwrap(document.image(offset: 10).cgImagePreservingBacking())

        // 重复行存在多个同样成立的位移，不能凭较小偏移猜测并覆盖已捕获正文
        XCTAssertNil(ScrollOffsetEstimator().estimate(from: current, to: previous))
    }

    func testChatChromePreservesSmallMovesAndManualReverseScroll() throws {
        let document = ScrollDocument(height: 1_100, headerHeight: 152, footerHeight: 152)
        var previousOffset = 0
        var previous = try XCTUnwrap(document.image().cgImagePreservingBacking())
        for offset in [48, 96, 192, 156, 260, 380, 468] {
            let current = try XCTUnwrap(document.image(offset: offset).cgImagePreservingBacking())
            let estimate = try XCTUnwrap(ScrollOffsetEstimator().estimate(from: current, to: previous))
            XCTAssertEqual(estimate.translation.y, CGFloat(offset - previousOffset))
            previous = current
            previousOffset = offset
        }
    }

    func testFullChatPageKeepsEveryPixelAndReachesTheBottomWithinFrameBudget() throws {
        let document = ScrollDocument(height: 1_100, headerHeight: 152, footerHeight: 152)
        let stitcher = ScrollStitcher()
        let bottom = 9_044
        // 对应 2x 屏幕上的 60 条聊天记录，包含两个 76 点的固定栏
        let offsets = [0, 132, 264, 396, 528, 396, 528] + Array(stride(from: 660, to: bottom, by: 132)) + [bottom]
        var maximumOffset = -1
        for offset in offsets {
            let expected: ScrollStitcher.Outcome = offset > maximumOffset ? .appended : .revisited
            XCTAssertEqual(stitcher.add(try document.image(offset: offset)), expected, "offset=\(offset)")
            maximumOffset = max(maximumOffset, offset)
        }
        XCTAssertFalse(stitcher.reachedFrameLimit)
        XCTAssertFalse(stitcher.isIncomplete)
        let result = try XCTUnwrap(try XCTUnwrap(stitcher.takeImage()).cgImagePreservingBacking())
        let expected = try XCTUnwrap(ScrollDocument(
            height: 10_144, headerHeight: 152, footerHeight: 152
        ).image().cgImagePreservingBacking())
        XCTAssertEqual(result.height, expected.height)
        // 图像提供者可以持有预留容量，只比较实际像素，不把未使用缓冲当作图像内容
        XCTAssertEqual(Data((try XCTUnwrap(result.dataProvider?.data) as Data).prefix(result.height * result.bytesPerRow)),
                       Data((try XCTUnwrap(expected.dataProvider?.data) as Data).prefix(expected.height * expected.bytesPerRow)))
    }
}

/// A document with distinct text-like lines and optional videos in document coordinates.
private struct ScrollDocument {
    let width = 300
    var height = 600
    var headerHeight = 40
    var footerHeight = 0
    var videoRows: [Range<Int>] = []
    var videoColumns: Range<Int>?
    var textSeed = 0
    var repeatRows: Int?
    var caret = false
    var panningPeriod: Double?

    func image(offset: Int = 0, frame: Int = 0) throws -> NSImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let columns = videoColumns ?? (0..<width)
        for y in 0..<height {
            let documentRow = y - headerHeight + offset
            let isVideoRow = y >= headerHeight && videoRows.contains { $0.contains(documentRow) }
            for x in 0..<width {
                let index = (y * width + x) * 4
                if isVideoRow, columns.contains(x) {
                    let color: (UInt8, UInt8, UInt8)
                    if let panningPeriod {
                        let phase = 2 * Double.pi * Double(documentRow + 2 * frame) / panningPeriod
                        let shade = UInt8(128 + 110 * sin(phase) * (0.6 + 0.4 * cos(Double(x) / 13)))
                        color = (shade, shade, shade)
                    } else {
                        let value = hash(x, documentRow, seed: 1_000 + frame)
                        color = (UInt8(truncatingIfNeeded: value >> 48), UInt8(truncatingIfNeeded: value >> 32),
                                 UInt8(truncatingIfNeeded: value >> 24))
                    }
                    (bytes[index], bytes[index + 1], bytes[index + 2]) = color
                    continue
                }

                let shade: UInt8
                if caret, (150..<152).contains(x), (300..<324).contains(y) {
                    shade = frame.isMultiple(of: 2) ? 0 : 255
                } else if y < headerHeight {
                    shade = (x / 6 + y / 5).isMultiple(of: 3) ? 40 : 230
                } else if y >= height - footerHeight {
                    shade = (x / 7 + (height - y) / 6).isMultiple(of: 3) ? 60 : 210
                } else {
                    shade = textShade(x: x, row: repeatRows.map { documentRow % $0 } ?? documentRow)
                }
                bytes[index] = shade
                bytes[index + 1] = shade
                bytes[index + 2] = shade
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let raster = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return NSImage(cgImage: raster, size: NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2))
    }

    private func textShade(x: Int, row: Int) -> UInt8 {
        // Each line picks its own 8-by-24 glyph bitmaps, with blank line and word spacing.
        let line = row / 36
        let glyphY = row % 36 - 8
        guard (0..<24).contains(glyphY), x >= 20, x <= width - 30 else { return 255 }
        let cell = (x - 20) / 10
        let glyphX = (x - 20) % 10
        guard glyphX < 8 else { return 255 }
        let glyph = Int(UInt8(truncatingIfNeeded: hash(line, cell, seed: 7 + textSeed) >> 48))
        guard !glyph.isMultiple(of: 7) else { return 255 }
        let bit = UInt8(truncatingIfNeeded: hash(glyph % 40, glyphX + glyphY * 8, seed: 3) >> 48)
        return bit.isMultiple(of: 3) ? 30 : 255
    }

    private func hash(_ x: Int, _ y: Int, seed: Int) -> UInt64 {
        let key = UInt64(x * 1_000_003 + y * 7_919 + seed * 104_729 + 1)
        let mixed = key &* 6_364_136_223_846_793_005
        return (mixed ^ (mixed >> 17)) &* 1_442_695_040_888_963_407
    }
}
