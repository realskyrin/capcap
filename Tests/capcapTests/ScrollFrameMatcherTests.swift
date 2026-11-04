import AppKit
import CoreGraphics
import CoreText
import XCTest

@testable import capcap

final class ScrollFrameMatcherTests: XCTestCase {
    private let matcher = ScrollFrameMatcher()

    func testNativeTextOnTranslucentGradientCardsMatchesUnevenScrollSequence() {
        let offsets = [0, 52, 212, 372, 532, 692, 852, 1012]
        let frames = offsets.map(nativeGradientPanel)
        var longest: TimeInterval = 0
        for index in 1..<frames.count {
            let started = Date.timeIntervalSinceReferenceDate
            let alignment = aligned(matcher.match(previous: frames[index - 1], current: frames[index]))
            longest = max(longest, Date.timeIntervalSinceReferenceDate - started)
            XCTAssertEqual(alignment?.shift, offsets[index] - offsets[index - 1])
        }
        print("ScrollFrameMatcher 992x1016 translucent native-text sequence, slowest pair: \(longest) seconds")
    }

    func testMatchesDocumentRowsDespiteRepeatedListLayoutAndSmallRenderingChanges() {
        let previous = frame(offset: 0)
        let current = frame(offset: 97, renderingDelta: 2)
        let alignment = aligned(matcher.match(previous: previous, current: current, expectedShift: 72))
        XCTAssertEqual(alignment?.shift, 97)
        XCTAssertEqual(alignment?.fixedBottom, 0)
    }

    func testDetectsFixedHeaderAndBlackBottomBorderInBackingPixelRows() {
        let previous = frame(offset: 0, top: 38, bottom: 14)
        let current = frame(offset: 80, top: 38, bottom: 14)
        let alignment = aligned(matcher.match(previous: previous, current: current))
        XCTAssertEqual(alignment?.shift, 80)
        XCTAssertEqual(alignment?.fixedTop, 38)
        XCTAssertEqual(alignment?.fixedBottom, 14)
    }

    func testFixedBottomIncludesItsWhitePaddingAboveABlackBorder() {
        let alignment = aligned(matcher.match(
            previous: frame(offset: 0, bottom: 18, bottomPadding: 10),
            current: frame(offset: 73, bottom: 18, bottomPadding: 10)
        ))
        XCTAssertEqual(alignment?.shift, 73)
        XCTAssertEqual(alignment?.fixedBottom, 18)
    }

    func testLargeFixedFooterIsExcludedBeforeGlobalOverlapValidation() {
        let alignment = aligned(matcher.match(
            previous: frame(offset: 0, top: 38, bottom: 70),
            current: frame(offset: 180, top: 38, bottom: 70), expectedShift: 180
        ))
        XCTAssertEqual(alignment?.shift, 180)
        XCTAssertGreaterThanOrEqual(alignment?.fixedBottom ?? 0, 70)
    }

    func testHighResolutionRenderedTextKeepsOriginalPixelShiftAndReportsLatency() {
        let document = renderedTextDocument()
        let previous = document.cropping(to: CGRect(x: 0, y: 0, width: 2880, height: 1440))!
        let current = document.cropping(to: CGRect(x: 0, y: 173, width: 2880, height: 1440))!
        let started = Date.timeIntervalSinceReferenceDate
        let alignment = aligned(matcher.match(previous: previous, current: current))
        let elapsed = Date.timeIntervalSinceReferenceDate - started
        print("ScrollFrameMatcher 2880x1440 rendered text, 173 px: \(elapsed) seconds")
        XCTAssertEqual(alignment?.shift, 173)
    }

    func testEverySmallTerminalMovementIsKeptAtPixelPrecision() {
        for distance in 1...7 {
            let alignment = aligned(matcher.match(previous: frame(offset: 11), current: frame(offset: 11 + distance)))
            XCTAssertEqual(alignment?.shift, distance, "Terminal scroll of \(distance) px")
        }
    }

    func testUnprovenSmallChangeDoesNotCreateASeamOrClaimTheFrameIsUnchanged() {
        let previous = frame(offset: 0)
        let current = frame(offset: 0, animatedPatch: true)
        guard case .unmatched = matcher.match(previous: previous, current: current) else {
            return XCTFail("A changing patch alone cannot prove scrolling or unchanged content")
        }
    }

    func testSparseContentEnteringBlankViewportIsNotSilentlyDiscarded() {
        let blank = makeImage(width: 192, height: 1000) { _, _ in 255 }
        let tail = makeImage(width: 192, height: 1000) { x, y in
            (80..<90).contains(x) && (990..<1000).contains(y) ? 0 : 255
        }
        guard case .unmatched = matcher.match(previous: blank, current: tail, expectedShift: 10) else {
            return XCTFail("An unalignable new word at the bottom is unresolved content, not an unchanged page")
        }
    }

    func testIdenticalBlankFramesRemainUnchanged() {
        let blank = makeImage(width: 192, height: 1000) { _, _ in 255 }
        guard case .unchanged = matcher.match(previous: blank, current: blank) else {
            return XCTFail("Identical blank frames need no seam")
        }
    }

    func testSmallDynamicPatchDoesNotPreventARealScroll() {
        let alignment = aligned(matcher.match(previous: frame(offset: 0), current: frame(offset: 83, animatedPatch: true)))
        XCTAssertEqual(alignment?.shift, 83)
    }

    func testRejectsMatchingIslandsWhenMostMovingContentContradictsTheSeam() {
        guard case .unmatched = matcher.match(
            previous: frame(offset: 0), current: frame(offset: 83, corruptAfter: 110), expectedShift: 83
        ) else {
            return XCTFail("A few matching bands cannot outweigh a mostly unrelated overlap")
        }
    }

    func testMatchesNarrowTextColumnWithStrongSupportThroughoutTheHeight() {
        let alignment = aligned(matcher.match(
            previous: frame(offset: 0, narrowColumn: true), current: frame(offset: 83, narrowColumn: true)
        ))
        XCTAssertEqual(alignment?.shift, 83)
    }

    func testUnrelatedFramesAreRejectedEvenWhenAWheelDistanceWasRequested() {
        guard case .unmatched = matcher.match(previous: noise(seed: 3), current: noise(seed: 19), expectedShift: 110) else {
            return XCTFail("A wheel request cannot justify appending unrelated pixels")
        }
    }

    func testJumpBeyondTheViewportIsRejectedRatherThanAppendingAWholeFrame() {
        guard case .unmatched = matcher.match(previous: frame(offset: 0), current: frame(offset: 731), expectedShift: 731) else {
            return XCTFail("Disjoint document regions have no safe seam")
        }
    }

    func testReverseMovementIsIgnored() {
        guard case .unchanged = matcher.match(previous: frame(offset: 120), current: frame(offset: 31)) else {
            return XCTFail("Scrolling back over captured content must not duplicate it")
        }
    }

    func testDimensionChangeIsNotAValidOverlap() {
        guard case .unmatched = matcher.match(previous: frame(offset: 0), current: noise(seed: 3, width: 241)) else {
            return XCTFail("A resized capture must be rejected")
        }
    }

    func testOrdinaryBlankDocumentTailIsNotRemovedAsFixedChrome() {
        let previous = frame(offset: 0, blankAfter: 270)
        let current = frame(offset: 43, blankAfter: 270)
        let alignment = aligned(matcher.match(previous: previous, current: current))
        XCTAssertEqual(alignment?.shift, 43)
        XCTAssertEqual(alignment?.fixedBottom, 0)
    }

    private func aligned(_ result: ScrollFrameMatcher.Match, file: StaticString = #filePath, line: UInt = #line) -> ScrollFrameMatcher.Alignment? {
        guard case let .aligned(alignment) = result else {
            XCTFail("Expected a pixel-verified downward alignment", file: file, line: line)
            return nil
        }
        return alignment
    }

    /// A white list with repeated row structure and deterministic, distinct
    /// glyph-like blocks. The fixtures encode document coordinates directly;
    /// they do not share the matcher's registration/scoring implementation.
    private func frame(
        offset: Int, top: Int = 0, bottom: Int = 0, renderingDelta: Int = 0,
        animatedPatch: Bool = false, blankAfter: Int? = nil,
        corruptAfter: Int? = nil, narrowColumn: Bool = false, bottomPadding: Int = 0
    ) -> CGImage {
        makeImage(width: 240, height: 360) { x, y in
            if y < top {
                return y == top - 1 ? 65 : (x > 18 && x < 210 && y > 8 && y < 24 ? 105 : 224)
            }
            if y >= 360 - bottom { return y < 360 - bottom + bottomPadding ? 247 : 18 }
            if let corruptAfter, y >= corruptAfter {
                var mixed = UInt64(y * 240 + x + 1) &* 6_364_136_223_846_793_005
                mixed ^= mixed >> 17
                mixed = mixed &* 1_442_695_040_888_963_407
                return Int((mixed >> 32) & 255)
            }
            if animatedPatch, (24..<37).contains(x), (104..<115).contains(y) { return 70 }
            let documentY = y - top + offset
            if let blankAfter, documentY >= blankAfter { return 247 }
            let row = documentY / 29
            let rowY = documentY % 29
            var value = 247
            if rowY == 27, !narrowColumn { value = 215 }
            if (5..<17).contains(rowY), x >= 14, x < (narrowColumn ? 50 : 222) {
                let character = (x - 14) / 9
                let characterX = (x - 14) % 9
                // Stable row-specific letters prevent a repeated list layout
                // from being mistaken for a different occurrence of the row.
                let bits = UInt64(row + 1) &* 6_364_136_223_846_793_005 &+ UInt64(character + 3) &* 1_442_695_040_888_963_407
                let stroke = (bits >> UInt64((rowY + characterX) % 37)) & 1
                if characterX < 6, stroke == 1 { value = 38 + Int(bits % 58) }
            }
            return min(255, value + renderingDelta)
        }
    }

    private func noise(seed: UInt64, width: Int = 240) -> CGImage {
        var state = seed
        return makeImage(width: width, height: 360) { _, _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) & 255)
        }
    }

    private func renderedTextDocument() -> CGImage {
        let context = CGContext(
            data: nil, width: 2880, height: 4200, bitsPerComponent: 8, bytesPerRow: 2880 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2880, height: 4200))
        let font = NSFont.monospacedSystemFont(ofSize: 28, weight: .regular)
        for row in 0..<60 {
            let text = NSAttributedString(
                string: "运行记录 \(row + 1)  Inspection \(1000 + row * 17)  设备在线  处理进度 \(row * 13 % 101)%  Safety review \(row * 29)",
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            context.textPosition = CGPoint(x: 48, y: 4120 - row * 64)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        return context.makeImage()!
    }

    /// Models the real capture's fixed gradient, translucent repeated controls,
    /// clipped first/last cards and native antialiased text without local files.
    private func nativeGradientPanel(offset: Int) -> CGImage {
        let width = 992, height = 1016
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 42, cornerHeight: 42, transform: nil))
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor(white: 0.13, alpha: 1).cgColor, NSColor(white: 0.20, alpha: 1).cgColor] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        func text(_ text: String, x: Int, top: Int, size: CGFloat) {
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor(white: 0.94, alpha: 1)]
            )
            context.textPosition = CGPoint(x: x, y: height - top)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        text("快捷键", x: 44, top: 72, size: 38)
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 16, width: width, height: height - 120))
        let labels = ["截图", "复制到剪贴板", "保存到文件", "上一张历史截图", "下一张历史截图", "历史面板", "截全屏", "取色器", "滚动截图", "屏幕录制", "文字识别", "翻译文字", "固定到屏幕", "搜索历史", "图像编辑", "复制颜色", "切换工具", "添加标注", "绘制箭头", "关闭面板"]
        for row in labels.indices {
            let top = 112 + row * 118 - offset
            let card = CGRect(x: 44, y: height - top - 92, width: 874, height: 92)
            let cardPath = CGPath(roundedRect: card, cornerWidth: 24, cornerHeight: 24, transform: nil)
            context.setFillColor(gray: 1, alpha: 0.035)
            context.addPath(cardPath)
            context.fillPath()
            context.setStrokeColor(gray: 1, alpha: 0.09)
            context.setLineWidth(2)
            context.addPath(cardPath)
            context.strokePath()
            text(labels[row], x: 72, top: top + 58, size: 28)
            context.setFillColor(gray: 1, alpha: 0.08)
            context.addPath(CGPath(roundedRect: CGRect(x: 574, y: height - top - 70, width: 218, height: 46), cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
            text(row < 5 ? ["⇧⌘A", "双击 ⌘", "⌘S", ",", "."][row] : "未设置", x: 606, top: top + 58, size: 26)
            text("录制", x: 818, top: top + 58, size: 25)
        }
        context.restoreGState()
        return context.makeImage()!
    }

    private func makeImage(width: Int, height: Int, value: (Int, Int) -> Int) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let gray = UInt8(value(x, y))
                let index = (y * width + x) * 4
                pixels[index] = gray
                pixels[index + 1] = gray
                pixels[index + 2] = gray
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}
