import AppKit
import os
import XCTest
@testable import capcap

// 图案生成参考 ScrollSnap 74a613b 的测试，MIT 版权见 ThirdParty/ScrollSnap
final class ScrollStitcherTests: XCTestCase {
    func testStationaryFrameDoesNotGrowImage() throws {
        let frame = makeImage(top: 0)
        let stitcher = ScrollStitcher()

        XCTAssertEqual(stitcher.add(frame), .appended)
        XCTAssertEqual(stitcher.add(frame), .unchanged)
        XCTAssertEqual(try XCTUnwrap(stitcher.image).size.height, 160)
        XCTAssertFalse(stitcher.isIncomplete)
    }

    func testRealMatcherFindsMovementWithPinnedHeaderAndAnimatedColumn() throws {
        for scale in [1, 2] {
            let previous = try XCTUnwrap(makeImage(top: 0, scale: scale, header: true, animation: true).cgImagePreservingBacking())
            let current = try XCTUnwrap(makeImage(top: 32, scale: scale, header: true, animation: true).cgImagePreservingBacking())
            let estimate = try XCTUnwrap(ScrollOffsetEstimator().estimate(from: current, to: previous))

            XCTAssertEqual(estimate.translation.x, 0)
            XCTAssertEqual(estimate.translation.y, CGFloat(32 * scale))
        }
    }

    func testDifferentBlankFramesDoNotEstablishMovement() throws {
        let previous = try XCTUnwrap(makeSolidImage(gray: 0.1).cgImagePreservingBacking())
        let current = try XCTUnwrap(makeSolidImage(gray: 0.8).cgImagePreservingBacking())

        XCTAssertNil(ScrollOffsetEstimator().estimate(from: current, to: previous))
    }

    func testAnimatedColumnDoesNotPreventStationaryBodyDetection() throws {
        let first = makeImage(top: 0, header: true, animation: true)
        let changed = makeImage(top: 0, header: true, animation: true, animationValue: 120)
        let estimate = try XCTUnwrap(ScrollOffsetEstimator().estimate(
            from: XCTUnwrap(changed.cgImagePreservingBacking()),
            to: XCTUnwrap(first.cgImagePreservingBacking())
        ))
        XCTAssertEqual(estimate.translation.y, 0)
    }

    func testMovingBannerDoesNotShiftTheStationaryPage() throws {
        let previous = try XCTUnwrap(makeImage(top: 0).cgImagePreservingBacking())
        let current = try XCTUnwrap(makeImage(
            top: 5, movingRegion: CGRect(x: 0, y: 0, width: 64, height: 20)
        ).cgImagePreservingBacking())
        let estimate = ScrollOffsetEstimator().estimate(from: current, to: previous)
        // 顶部小广告的移动不能把整页正文向前拼接
        XCTAssertTrue(estimate == nil || estimate?.translation.y == 0)
    }

    func testFullWidthMovingBannerDoesNotShiftTheStationaryPage() throws {
        let previous = try XCTUnwrap(makeImage(top: 0).cgImagePreservingBacking())
        let current = try XCTUnwrap(makeImage(
            top: 5, movingRegion: CGRect(x: 0, y: 50, width: 96, height: 20)
        ).cgImagePreservingBacking())
        // 短正文的支持不能让独立移动的横幅成为整页的滚动证据
        let estimate = ScrollOffsetEstimator().estimate(from: current, to: previous)
        XCTAssertTrue(estimate == nil || estimate?.translation.y == 0)
    }

    func testFixedSidebarsCannotHideAProvenMovingColumn() throws {
        let previous = try XCTUnwrap(makeImage(top: 0).cgImagePreservingBacking())
        let current = try XCTUnwrap(makeImage(
            top: 5, movingRegion: CGRect(x: 32, y: 0, width: 32, height: 160)
        ).cgImagePreservingBacking())
        let estimate = ScrollOffsetEstimator().estimate(from: current, to: previous)
        XCTAssertTrue(estimate == nil || estimate?.translation.y == 5)
    }

    func testFixedSidebarsCannotTurnAmbiguousBodyScrollIntoPageEnd() throws {
        let region = CGRect(x: 64, y: 0, width: 32, height: 160)
        let previous = try XCTUnwrap(makeImage(top: 0, movingRegion: region, repeatRows: 8).cgImagePreservingBacking())
        let current = try XCTUnwrap(makeImage(top: 3, movingRegion: region, repeatRows: 8).cgImagePreservingBacking())
        let estimate = ScrollOffsetEstimator().estimate(from: current, to: previous)
        XCTAssertTrue(estimate == nil || estimate?.translation.y == 3)
    }

    func testNewlyVisibleBodyIsNotHiddenByStaticSidebars() throws {
        let previous = try XCTUnwrap(makeImage(top: 0, animation: true, animationValue: 255).cgImagePreservingBacking())
        let current = try XCTUnwrap(makeImage(top: 0).cgImagePreservingBacking())
        // 新加载的正文同样需要解释，不能只因另一侧没有变化就判断已经滚到底
        XCTAssertNil(ScrollOffsetEstimator().estimate(from: current, to: previous))
    }

    func testShortViewportTracksReverseWithoutChangingDownwardOnlyMatcher() throws {
        let previous = try XCTUnwrap(makeImage(top: 5, height: 24).cgImagePreservingBacking())
        let current = try XCTUnwrap(makeImage(top: 0, height: 24).cgImagePreservingBacking())
        let estimate = try XCTUnwrap(ScrollOffsetEstimator().estimate(from: current, to: previous))
        XCTAssertEqual(estimate.translation.y, -5)
        guard case .unchanged = ScrollFrameMatcher().match(previous: previous, current: current) else {
            return XCTFail("默认匹配器仍应忽略向上滚动")
        }
    }

    func testRealMatcherReplayPreservesEveryRowAtBothScales() throws {
        for scale in [1, 2] {
            let stitcher = ScrollStitcher()
            for top in stride(from: 0, through: 128, by: 32) {
                XCTAssertEqual(stitcher.add(makeImage(top: top, scale: scale)), .appended)
            }
            XCTAssertEqual(
                try pixels(of: XCTUnwrap(stitcher.image)),
                try pixels(of: makeImage(top: 0, height: 288, scale: scale))
            )
        }
    }

    func testDownUpDownPreservesExtentAndDoesNotDuplicateRows() throws {
        let stitcher = ScrollStitcher(estimator: SequenceScrollEstimator([40, -20, 40]))

        XCTAssertEqual(stitcher.add(makeImage(top: 0)), .appended)
        XCTAssertEqual(stitcher.add(makeImage(top: 40)), .appended)
        XCTAssertEqual(stitcher.add(makeImage(top: 20)), .revisited)
        XCTAssertEqual(try XCTUnwrap(stitcher.image).size.height, 200)
        XCTAssertEqual(stitcher.add(makeImage(top: 60)), .appended)

        let image = try XCTUnwrap(stitcher.image)
        XCTAssertEqual(image.size.height, 220)
        XCTAssertEqual(try pixels(of: image), try pixels(of: makeImage(top: 0, height: 220)))
    }

    func testStationaryFrameCanFillDelayedTailAndContinueStitching() throws {
        let ready = makeImage(top: 32)
        let backing = try XCTUnwrap(ready.cgImagePreservingBacking())
        var delayed = try packedPixels(of: ready)
        // 模拟新露出的底部 32 行尚未绘制，稳定帧应补齐这部分像素
        delayed.replaceSubrange((128 * backing.bytesPerRow)..<delayed.count,
                                with: repeatElement(UInt8(255), count: 32 * backing.bytesPerRow))
        let pending = try image(bytes: Array(delayed), width: backing.width, height: backing.height,
                                size: ready.size, bitsPerComponent: backing.bitsPerComponent,
                                space: try XCTUnwrap(backing.colorSpace), bitmapInfo: backing.bitmapInfo)
        let stitcher = ScrollStitcher(estimator: SequenceScrollEstimator([32, 0, 32]))
        XCTAssertEqual(stitcher.add(makeImage(top: 0)), .appended)
        XCTAssertEqual(stitcher.add(pending), .appended)
        XCTAssertEqual(stitcher.add(ready), .unchanged)
        XCTAssertEqual(try packedPixels(of: XCTUnwrap(stitcher.image)),
                       try packedPixels(of: makeImage(top: 0, height: 192)))
        XCTAssertEqual(stitcher.add(makeImage(top: 64)), .appended)
        XCTAssertEqual(try packedPixels(of: XCTUnwrap(stitcher.takeImage())),
                       try packedPixels(of: makeImage(top: 0, height: 224)))
    }

    func testUnmatchedFrameRetainsReliableAnchorAndLaterFrameRecovers() throws {
        let estimator = SequenceScrollEstimator([nil, 40])
        let stitcher = ScrollStitcher(estimator: estimator)
        let initial = makeImage(top: 0)
        stitcher.add(initial)

        XCTAssertEqual(stitcher.add(makeSolidImage(gray: 0.5)), .unmatched)
        XCTAssertTrue(stitcher.isIncomplete)
        XCTAssertEqual(try pixels(of: XCTUnwrap(stitcher.image)), try pixels(of: initial))
        XCTAssertEqual(stitcher.add(makeImage(top: 40)), .appended)

        let anchors = estimator.anchors
        XCTAssertEqual(anchors.count, 2)
        XCTAssertTrue(anchors[0] === anchors[1])
        XCTAssertFalse(stitcher.isIncomplete)
        XCTAssertEqual(try pixels(of: XCTUnwrap(stitcher.image)), try pixels(of: makeImage(top: 0, height: 200)))
    }

    func testRetinaOutputKeepsPixelResolutionAndAppendsBottomRows() throws {
        let stitcher = ScrollStitcher(estimator: SequenceScrollEstimator([64]))
        stitcher.add(makeImage(top: 0, scale: 2))
        XCTAssertEqual(stitcher.add(makeImage(top: 32, scale: 2)), .appended)

        let image = try XCTUnwrap(stitcher.image)
        let backing = try XCTUnwrap(image.cgImagePreservingBacking())
        XCTAssertEqual(image.size, NSSize(width: 96, height: 192))
        XCTAssertEqual(backing.width, 192)
        XCTAssertEqual(backing.height, 384)
        XCTAssertEqual(try pixels(of: image), try pixels(of: makeImage(top: 0, height: 192, scale: 2)))
    }

    func testFrameLimitPreservesAlreadyStitchedContent() throws {
        let stitcher = ScrollStitcher(estimator: SequenceScrollEstimator([32, 32]), maxFrames: 2)
        stitcher.add(makeImage(top: 0))
        XCTAssertEqual(stitcher.add(makeImage(top: 32)), .appended)
        let accepted = try pixels(of: XCTUnwrap(stitcher.image))

        XCTAssertEqual(stitcher.add(makeImage(top: 64)), .atFrameLimit)
        XCTAssertTrue(stitcher.reachedFrameLimit)
        XCTAssertEqual(try pixels(of: XCTUnwrap(stitcher.image)), accepted)
    }

    func testDimensionChangeIsRejectedWithoutDiscardingCapture() throws {
        let stitcher = ScrollStitcher(estimator: SequenceScrollEstimator([32]))
        stitcher.add(makeImage(top: 0))

        XCTAssertEqual(stitcher.add(makeImage(top: 32, scale: 2)), .unmatched)
        XCTAssertTrue(stitcher.isIncomplete)
        XCTAssertEqual(try XCTUnwrap(stitcher.image).size, NSSize(width: 96, height: 160))
    }

    func testP3AndHalfFloatFramesKeepFirstFrameFormatAndRawPixels() throws {
        for halfFloat in [false, true] {
            let first = try makeColorImage(top: 0, halfFloat: halfFloat)
            let template = try XCTUnwrap(first.cgImagePreservingBacking())
            XCTAssertEqual(template.bitsPerComponent, halfFloat ? 16 : 8)
            XCTAssertEqual(template.bitsPerPixel, halfFloat ? 64 : 32)
            let stitcher = ScrollStitcher(estimator: SequenceScrollEstimator([32, 32]))

            for top in [0, 32, 64] {
                XCTAssertEqual(stitcher.add(try makeColorImage(top: top, halfFloat: halfFloat)), .appended)
            }
            let result = try XCTUnwrap(stitcher.takeImage())
            let backing = try XCTUnwrap(result.cgImagePreservingBacking())
            XCTAssertEqual(backing.colorSpace, template.colorSpace)
            XCTAssertEqual(backing.bitmapInfo, template.bitmapInfo)
            XCTAssertEqual(backing.bitsPerComponent, template.bitsPerComponent)
            XCTAssertEqual(backing.bitsPerPixel, template.bitsPerPixel)
            XCTAssertEqual(
                try packedPixels(of: result),
                try packedPixels(of: makeColorImage(top: 0, height: 224, halfFloat: halfFloat))
            )
        }
    }

    func testIncompatibleColorSpaceOrPixelFormatKeepsAnchorAndCanRecover() throws {
        let first = try makeColorImage(top: 0)
        let incompatible = [
            try makeColorImage(top: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!),
            try makeColorImage(top: 32, halfFloat: true)
        ]
        for frame in incompatible {
            let estimator = SequenceScrollEstimator([32])
            let stitcher = ScrollStitcher(estimator: estimator)
            XCTAssertEqual(stitcher.add(first), .appended)
            XCTAssertEqual(stitcher.add(frame), .unmatched)
            XCTAssertTrue(stitcher.isIncomplete)
            XCTAssertTrue(estimator.anchors.isEmpty)
            XCTAssertEqual(try packedPixels(of: XCTUnwrap(stitcher.image)), try packedPixels(of: first))
            XCTAssertEqual(stitcher.add(try makeColorImage(top: 32)), .appended)
            XCTAssertFalse(stitcher.isIncomplete)
            XCTAssertEqual(
                try packedPixels(of: XCTUnwrap(stitcher.takeImage())),
                try packedPixels(of: makeColorImage(top: 0, height: 192))
            )
        }
    }

    func testPublishedImageAndThumbnailAreIndependentOfLaterWrites() throws {
        let stitcher = ScrollStitcher(estimator: SequenceScrollEstimator([32, 32]))
        XCTAssertEqual(stitcher.add(makeImage(top: 0)), .appended)
        XCTAssertEqual(stitcher.add(makeImage(top: 32)), .appended)
        let snapshot = try XCTUnwrap(stitcher.image)
        let thumbnail = try XCTUnwrap(stitcher.thumbnail())
        let snapshotPixels = try pixels(of: snapshot)
        let thumbnailPixels = try pixels(of: thumbnail)

        // 强制位移使刷新区确实改色，避免仅追加相同正文掩盖共享缓冲区泄漏
        XCTAssertEqual(stitcher.add(makeImage(top: 64, animation: true, animationValue: 120)), .appended)
        XCTAssertEqual(try pixels(of: snapshot), snapshotPixels)
        XCTAssertEqual(try pixels(of: thumbnail), thumbnailPixels)
        XCTAssertEqual(snapshot.size.height, 192)
        XCTAssertEqual(thumbnail.size.height, 192)
        XCTAssertEqual(try XCTUnwrap(stitcher.takeImage()).size.height, 224)
        XCTAssertNil(stitcher.image)
        XCTAssertNil(stitcher.thumbnail())
    }

    func testHundredFramesKeepAllRowsAcrossBufferGrowth() throws {
        let stitcher = ScrollStitcher(estimator: SequenceScrollEstimator(Array(repeating: 32, count: 100)))
        for index in 0..<100 {
            XCTAssertEqual(stitcher.add(makeImage(top: index * 32)), .appended, "Frame \(index)")
        }
        XCTAssertEqual(stitcher.add(makeImage(top: 3_200)), .atFrameLimit)
        let result = try XCTUnwrap(stitcher.takeImage())
        XCTAssertEqual(result.size, NSSize(width: 96, height: 3_328))
        XCTAssertEqual(try packedPixels(of: result), try packedPixels(of: makeImage(top: 0, height: 3_328)))
    }

    func testTallFixedHeaderAndFooterAppearOnlyOnceAtBothScales() throws {
        for scale in [1, 2] {
            let stitcher = ScrollStitcher()
            for offset in [0, 37, 65, 66] {
                XCTAssertEqual(stitcher.add(try pinnedViewport(offset: offset, scale: scale)), .appended)
            }
            let result = try XCTUnwrap(stitcher.takeImage())
            XCTAssertEqual(result.size, NSSize(width: 128, height: 306))
            XCTAssertEqual(
                try packedPixels(of: result),
                try packedPixels(of: pinnedViewport(offset: 0, height: 306, scale: scale))
            )
        }
    }

    // 沿用 main 的 ScrollImageStitcherTests 高吸顶页头和单行底栏场景，并覆盖 1x/2x
    private func pinnedViewport(offset: Int, height: Int = 240, scale: Int) throws -> NSImage {
        let width = 128 * scale
        let pixelHeight = height * scale
        let header = 104 * scale
        var bytes = [UInt8](repeating: 255, count: width * pixelHeight * 4)
        for y in 0..<(pixelHeight - scale) {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if y < header {
                    let shade: UInt8 = (x / (8 * scale) + y / (6 * scale)).isMultiple(of: 2) ? 70 : 200
                    bytes[index] = shade
                    bytes[index + 1] = shade
                    bytes[index + 2] = shade
                } else {
                    let row = y - header + offset * scale
                    var value = UInt64(row * width + x + 1) &* 6_364_136_223_846_793_005
                    value ^= value >> 17
                    value = value &* 1_442_695_040_888_963_407
                    bytes[index] = UInt8(truncatingIfNeeded: value >> 48)
                    bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 32)
                    bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 24)
                }
            }
        }
        return try image(bytes: bytes, width: width, height: pixelHeight, size: NSSize(width: 128, height: height),
                         bitsPerComponent: 8, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func makeColorImage(
        top: Int, height: Int = 160, halfFloat: Bool = false, space: CGColorSpace? = nil
    ) throws -> NSImage {
        let width = 96
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let red = UInt8(truncatingIfNeeded: x * 17 + (y + top) * 31)
                let green = UInt8(truncatingIfNeeded: x * 13 + (y + top) * 19)
                let blue = UInt8(truncatingIfNeeded: x * 7 + (y + top) * 11)
                if halfFloat {
                    // 包含大于 1 的分量，降成 8 位或 sRGB 会直接破坏原始值
                    for component in [Float16(red) / 200, Float16(green) / 200, Float16(blue) / 200, 1] {
                        let bits = component.bitPattern
                        bytes.append(UInt8(truncatingIfNeeded: bits))
                        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
                    }
                } else {
                    bytes.append(contentsOf: [blue, green, red, 255])
                }
            }
        }
        let info: CGBitmapInfo = halfFloat
            ? [.floatComponents, .byteOrder16Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
            : [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        let colorSpace = space ?? CGColorSpace(name: halfFloat ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.displayP3)!
        return try image(bytes: bytes, width: width, height: height, size: NSSize(width: width, height: height),
                         bitsPerComponent: halfFloat ? 16 : 8, space: colorSpace, bitmapInfo: info)
    }

    private func image(
        bytes: [UInt8], width: Int, height: Int, size: NSSize,
        bitsPerComponent: Int, space: CGColorSpace, bitmapInfo: CGBitmapInfo
    ) throws -> NSImage {
        let stride = bytes.count / height
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let backing = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: stride * 8 / width,
            bytesPerRow: stride, space: space, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return NSImage(cgImage: backing, size: size)
    }

    // 直接比较有效像素字节，不能先重绘到 sRGB 后把格式丢失误判为成功
    private func packedPixels(of image: NSImage) throws -> Data {
        let backing = try XCTUnwrap(image.cgImagePreservingBacking())
        let data = try XCTUnwrap(backing.dataProvider?.data) as Data
        let stride = (backing.width * backing.bitsPerPixel + 7) / 8
        var pixels = Data()
        for row in 0..<backing.height {
            pixels.append(data.subdata(in: (row * backing.bytesPerRow)..<(row * backing.bytesPerRow + stride)))
        }
        return pixels
    }

    private func makeImage(top: Int, height: Int = 160, scale: Int = 1, header: Bool = false, animation: Bool = false, animationValue: Int? = nil, movingRegion: CGRect? = nil, repeatRows: Int? = nil) -> NSImage {
        let width = 96 * scale
        let pixelHeight = height * scale
        let context = CGContext(
            data: nil, width: width, height: pixelHeight, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<pixelHeight {
            for x in 0..<width {
                let offset = movingRegion.map { $0.contains(CGPoint(x: x / scale, y: y / scale)) ? top : 0 } ?? top
                let row = y / scale + offset
                let patternedRow = movingRegion?.contains(CGPoint(x: x / scale, y: y / scale)) == true
                    ? repeatRows.map { row % $0 } ?? row : row
                var value = UInt8(truncatingIfNeeded: ((x / scale) * 17) ^ (patternedRow * 131))
                if header && y < 20 * scale { value = 80 }
                if animation && x >= width * 2 / 3 { value = UInt8(truncatingIfNeeded: animationValue ?? (top + 40)) }
                let index = y * context.bytesPerRow + x * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
                bytes[index + 3] = 255
            }
        }
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 96, height: height))
    }

    private func makeSolidImage(gray: CGFloat) -> NSImage {
        let context = CGContext(
            data: nil, width: 96, height: 160, bitsPerComponent: 8,
            bytesPerRow: 96 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 160))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 96, height: 160))
    }

    private func pixels(of image: NSImage) throws -> Data {
        let backing = try XCTUnwrap(image.cgImagePreservingBacking())
        let context = try XCTUnwrap(CGContext(
            data: nil, width: backing.width, height: backing.height, bitsPerComponent: 8,
            bytesPerRow: backing.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(backing, in: CGRect(x: 0, y: 0, width: backing.width, height: backing.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
}

private final class SequenceScrollEstimator: ScrollOffsetEstimating {
    private struct State {
        var shifts: [Int?]
        var anchors: [CGImage] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ shifts: [Int?]) {
        state = OSAllocatedUnfairLock(initialState: State(shifts: shifts))
    }

    var anchors: [CGImage] { state.withLock { $0.anchors } }

    func estimate(from currentImage: CGImage, to previousImage: CGImage) -> ScrollOffsetEstimate? {
        state.withLock {
            $0.anchors.append(previousImage)
            guard !$0.shifts.isEmpty, let shift = $0.shifts.removeFirst() else { return nil }
            return ScrollOffsetEstimate(translation: CGPoint(x: 0, y: CGFloat(shift)), confidence: 1, source: .pixelOverlap)
        }
    }
}
