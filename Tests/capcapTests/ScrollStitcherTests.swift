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

    private func makeImage(top: Int, height: Int = 160, scale: Int = 1, header: Bool = false, animation: Bool = false, animationValue: Int? = nil) -> NSImage {
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
                var value = UInt8(truncatingIfNeeded: ((x / scale) * 17) ^ ((y / scale + top) * 131))
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
