import CoreGraphics
import XCTest

@testable import capcap

/// Regression coverage for issue #135: a browser auto-snap captured the
/// window CGImage at `ceil(contentSize * scale)` backing pixels but tagged the
/// returned `NSImage` with `pointSize` — the overlay selection rect, a
/// separately measured quantity that diverges from the ScreenCaptureKit
/// content rect by sub-point rounding/titlebar handling. When that logical
/// size exceeded the backing pixel count, the editor/export left a transparent
/// vertical strip on the right edge. Manual selection was unaffected because
/// both dimensions came from the same rect.
///
/// The fix wraps the captured CGImage via `ScreenCapturer.windowImage(from:scale:)`,
/// which derives the `NSImage` logical size from the image's own pixel
/// dimensions (`logicalSize(forPixelWidth:scale:)`) so it is always
/// self-consistent at the display scale. `pointSize` is no longer used.
final class ScreenCapturerDimensionTests: XCTestCase {

    // MARK: - capture wiring (the actual #135 guard)

    /// The meaningful regression guard. `windowImage` is the seam that turns a
    /// captured `CGImage` into the editor's base image, so it must produce an
    /// `NSImage` whose logical size maps EXACTLY onto the image's own backing
    /// pixels (no transparent edge overhang) and must NOT adopt any overlay
    /// selection-rect size. Red before the fix (no `windowImage`), green after.
    func testWindowImageDerivesSizeFromActualPixelsAndIgnoresSelectionRect() {
        let scale: CGFloat = 2
        // Odd pixel width — the browser case, where a sub-point selection
        // remainder yields a non-integer point width that must still round-trip.
        let cgImage = Self.makeOpaqueCGImage(width: 801, height: 600)
        let image = ScreenCapturer.windowImage(from: cgImage, scale: scale)

        // Self-consistent with the ACTUAL backing pixels: logical size × scale
        // reproduces the CGImage pixel count exactly, so no edge can overhang
        // into transparent space (the mechanism behind the right blank strip).
        XCTAssertEqual(image.size.width * scale, CGFloat(cgImage.width), accuracy: 1e-9)
        XCTAssertEqual(image.size.height * scale, CGFloat(cgImage.height), accuracy: 1e-9)

        // The overlay selection rect is a larger, separately-measured quantity;
        // the wrapped image must not adopt it (that was the pre-fix behavior).
        let browserSelectionWidth: CGFloat = 400.7 // 400.7 × 2 = 801.4 > 801 → would overhang
        XCTAssertNotEqual(image.size.width, browserSelectionWidth)

        // The backing CGImage is preserved untouched.
        XCTAssertEqual(image.cgImagePreservingBacking()?.width, cgImage.width)
        XCTAssertEqual(image.cgImagePreservingBacking()?.height, cgImage.height)
    }

    /// `windowImage` must stay self-consistent even when the CGImage's pixel
    /// count does NOT equal the requested `config.width` (e.g. under
    /// `captureResolution = .best`). Tagging from the actual pixels — not from
    /// a requested width — is what guarantees this.
    func testWindowImageStaysSelfConsistentWhenPixelsDifferFromRequest() {
        let scale: CGFloat = 2
        // Simulate ScreenCaptureKit returning MORE pixels than requested.
        let cgImage = Self.makeOpaqueCGImage(width: 1600, height: 1000)
        let image = ScreenCapturer.windowImage(from: cgImage, scale: scale)

        XCTAssertEqual(image.size.width * scale, CGFloat(cgImage.width), accuracy: 1e-9)
        XCTAssertEqual(image.size.width, 800, accuracy: 1e-9) // 1600 / 2
    }

    // MARK: - logicalSize helper arithmetic

    /// The point-size ↔ pixel-width consistency invariant for fractional point
    /// widths at scale 2 (acceptance criterion #2). The overhang demo below
    /// shows why this matters; here we pin that the helper's output round-trips.
    func testLogicalSizeRoundTripsForFractionalPointWidthsAtScaleTwo() {
        let scale: CGFloat = 2
        for pointWidth: CGFloat in [400.3, 1200.7, 999.25, 1.5] {
            let pixelWidth = max(Int(ceil(pointWidth * scale)), 1)
            let logicalWidth = ScreenCapturer.logicalSize(forPixelWidth: pixelWidth, scale: scale)
            XCTAssertEqual(
                logicalWidth * scale,
                CGFloat(pixelWidth),
                accuracy: 1e-9,
                "logical width \(logicalWidth) at scale \(scale) must map back to pixel width \(pixelWidth)"
            )
        }
    }

    func testLogicalSizeRoundTripsAtScaleOne() {
        let scale: CGFloat = 1
        for pixelWidth in [1, 600, 1920] {
            let logicalWidth = ScreenCapturer.logicalSize(forPixelWidth: pixelWidth, scale: scale)
            XCTAssertEqual(logicalWidth, CGFloat(pixelWidth))
            XCTAssertEqual(logicalWidth * scale, CGFloat(pixelWidth), accuracy: 1e-9)
        }
    }

    /// Sub-unit, zero, and negative scales are clamped to 1 — matching the
    /// capture path's `max(scale, 1)` — so the point dimension never divides by
    /// a fraction or by zero.
    func testLogicalSizeClampsNonPositiveScaleToOne() {
        let pixelWidth = 800
        let atScaleOne = ScreenCapturer.logicalSize(forPixelWidth: pixelWidth, scale: 1)
        for badScale: CGFloat in [0.5, 0, -2] {
            XCTAssertEqual(
                ScreenCapturer.logicalSize(forPixelWidth: pixelWidth, scale: badScale),
                atScaleOne,
                accuracy: 1e-9
            )
        }
    }

    /// Non-positive pixel widths clamp to zero (defensive; not reachable from
    /// the capture path, which floors `config.width` at 1).
    func testLogicalSizeClampsNonPositivePixelWidthToZero() {
        XCTAssertEqual(ScreenCapturer.logicalSize(forPixelWidth: 0, scale: 2), 0)
        XCTAssertEqual(ScreenCapturer.logicalSize(forPixelWidth: -50, scale: 2), 0)
    }

    // MARK: - why the helper is needed (the pre-fix break, demonstrated)

    /// Demonstrates the pre-fix failure mode: when the logical size came from
    /// the selection rect (a separate, larger measurement) instead of the
    /// captured pixels, it demanded more backing pixels than the capture
    /// contained — the right-edge blank strip. The helper-derived size does not.
    func testSeparateSelectionRectOverhangsBackingPixelsButHelperDoesNot() {
        let scale: CGFloat = 2
        // Browser case: ScreenCaptureKit contentRect (drives backing pixels) is
        // slightly narrower than the overlay selection rect (drove the old size).
        let contentWidth: CGFloat = 1200.0
        let selectionWidth: CGFloat = 1200.7
        let pixelWidth = max(Int(ceil(contentWidth * scale)), 1) // 2400

        // Pre-fix: logical size came from the selection rect, demanding more
        // pixels than the 2400-pixel backing store could provide.
        XCTAssertGreaterThan(selectionWidth * scale, CGFloat(pixelWidth)) // 2401.4 > 2400 → overhang

        // Post-fix: logical size derives from the captured pixels → exact fit.
        XCTAssertEqual(
            ScreenCapturer.logicalSize(forPixelWidth: pixelWidth, scale: scale) * scale,
            CGFloat(pixelWidth),
            accuracy: 1e-9
        )
    }

    // MARK: - helpers

    private static func makeOpaqueCGImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        // Test-only force-unwrap: a valid RGB context always makes an image.
        return context!.makeImage()!
    }
}
