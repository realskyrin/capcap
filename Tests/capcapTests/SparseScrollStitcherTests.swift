import AppKit
import XCTest
@testable import capcap

@MainActor
final class SparseScrollStitcherTests: XCTestCase {
    func testSparseHeadingCannotHideTextThatWouldBeLostAtTheSeam() throws {
        let document = try sparseDocument()
        let before = try viewport(document, top: 160, height: 160)
        let after = try viewport(document, top: 880, height: 160)
        // 两处标题相似，但相距 720 像素，不能只凭“背景描述”错认成 20 像素
        XCTAssertNil(ScrollOffsetEstimator().estimate(from: after, to: before))
    }

    func testExactFallbackCannotIgnoreAContradictingChapterColumn() throws {
        let before = try columnDocument(top: 0)
        let after = try columnDocument(top: 90)
        // 右侧两列按 80 行重复，左侧编号列必须否决错误的 10 像素周期别名
        XCTAssertNil(ScrollOffsetEstimator().estimate(from: after, to: before))
    }

    func testForwardScrollCannotMistakeLaterSectionsForAReverseVisit() throws {
        let document = try sparseDocument()
        for (height, oldTop, newTop) in [(160, 400, 1000), (160, 1080, 1800),
                                        (240, 720, 1240), (240, 1440, 2400), (360, 1400, 2280)] {
            let before = try viewport(document, top: oldTop, height: height)
            let after = try viewport(document, top: newTop, height: height)
            let stitcher = ScrollStitcher()
            XCTAssertEqual(stitcher.add(NSImage(cgImage: before, size: NSSize(width: before.width, height: height))), .appended)
            XCTAssertEqual(stitcher.add(NSImage(cgImage: after, size: NSSize(width: after.width, height: height)),
                                        expectedScrollDirection: .down), .unmatched,
                           "height=\(height), \(oldTop)→\(newTop)")
            XCTAssertTrue(stitcher.isIncomplete)
            let result = try XCTUnwrap(try XCTUnwrap(stitcher.image).cgImagePreservingBacking())
            XCTAssertEqual(try pixels(result), try pixels(before))
        }
    }

    func testActualReverseScrollPreservesTheCapturedExtent() throws {
        let stitcher = ScrollStitcher()
        for (top, direction, outcome) in [(0, ScrollStitcher.ScrollDirection.down, ScrollStitcher.Outcome.appended),
                                          (20, .down, .appended), (10, .up, .revisited), (30, .down, .appended)] {
            let frame = try columnDocument(top: top)
            XCTAssertEqual(stitcher.add(NSImage(cgImage: frame, size: NSSize(width: 96, height: 160)),
                                        expectedScrollDirection: direction), outcome)
        }
        XCTAssertEqual(try XCTUnwrap(stitcher.image).size.height, 190)
    }

    private func viewport(_ document: CGImage, top: Int, height: Int) throws -> CGImage {
        try XCTUnwrap(document.cropping(to: CGRect(x: 0, y: top, width: document.width, height: height)))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        Data((try XCTUnwrap(image.dataProvider?.data) as Data).prefix(image.height * image.bytesPerRow))
    }

    private func columnDocument(top: Int) throws -> CGImage {
        let width = 96, height = 160
        var bytes = [UInt8](repeating: 255, count: width * height)
        for y in 30..<130 {
            for x in 0..<width {
                let row = x < 32 ? y - 30 + top : (y - 30 + top) % 80
                var hash = UInt32(row) &* 0x9E3779B9 &+ UInt32(x) &* 0x85EBCA6B
                hash ^= hash >> 16; hash &*= 0x7FEB352D; hash ^= hash >> 15
                bytes[y * width + x] = UInt8(10 + hash % 220)
            }
        }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                    provider: XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)),
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func sparseDocument() throws -> CGImage {
        let height = 3200
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 32))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: height).fill()
        let lines: [(String, CGFloat, CGFloat, Bool)] = [
            ("3. 背景描述", 30, 34, true), ("今天晚些时候，需要再次查看窗口", 110, 23, false),
            ("以下是一份常规产品说明文档", 155, 23, false), ("背景描述", 250, 32, true),
            ("项目当前由不同的业务模块组成", 330, 23, false), ("每一个模块都包含不同的页面", 380, 23, false),
            ("文档之间保留适当的空白", 430, 23, false), ("4. 需求分析", 610, 34, true),
            ("产品应支持页面内容的完整保存", 720, 23, false), ("再次查看时，保留原有的章节顺序", 765, 23, false),
            ("背景描述", 950, 32, true), ("项目当前由不同的业务模块组成", 1030, 23, false),
            ("每一个模块都包含不同的页面", 1080, 23, false), ("文档之间保留适当的空白", 1130, 23, false),
            ("4. 需求分析", 1310, 34, true), ("产品应支持页面内容的完整保存", 1420, 23, false),
            ("再次查看时，保留原有的章节顺序", 1465, 23, false), ("5. 功能说明", 1760, 34, true),
            ("保存内容不应重复也不能缺少", 1870, 23, false), ("每一个模块都包含不同的页面", 1915, 23, false),
            ("文档之间保留适当的空白", 2020, 23, false), ("6. 预期结果", 2400, 34, true),
            ("项目当前由不同的业务模块组成", 2520, 23, false), ("再次查看时，保留原有的章节顺序", 2580, 23, false)
        ]
        for (text, top, size, bold) in lines {
            (text as NSString).draw(at: NSPoint(x: 35, y: CGFloat(height) - top - size * 1.35),
                                   withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                                                    .foregroundColor: NSColor.black])
        }
        return try XCTUnwrap(bitmap.cgImage)
    }
}

final class ScrollCaptureInputTests: XCTestCase {
    func testDownwardInputRemainsKnownUntilACaptureUsesIt() {
        var input = ScrollCapturer.ScrollInput()
        input.record(deltaY: -20)
        XCTAssertEqual(input.direction, .down)
        let captured = input
        input.acknowledge(captured)
        XCTAssertNil(input.direction)
    }

    func testReverseInputAfterHittingBottomDoesNotUseNetWheelDistance() {
        var input = ScrollCapturer.ScrollInput()
        for _ in 0..<20 { input.record(deltaY: -100) }
        input.record(deltaY: 1)
        XCTAssertNil(input.direction)
    }

    func testInputArrivingDuringCaptureIsNotAcknowledgedEarly() {
        var input = ScrollCapturer.ScrollInput()
        input.record(deltaY: -10)
        let captured = input
        input.record(deltaY: 10)
        input.acknowledge(captured)
        XCTAssertEqual(input.direction, .up)
    }

    func testMissingAndInvalidWheelInputDoesNotInventADirection() {
        var input = ScrollCapturer.ScrollInput()
        for delta in [CGFloat.zero, .infinity, -.infinity, .nan] { input.record(deltaY: delta) }
        XCTAssertNil(input.direction)
    }
}
