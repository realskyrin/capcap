import XCTest
@testable import capcap

final class ScrollStitchQualityTests: XCTestCase {
    private func makeBitmapData(
        width: Int,
        height: Int,
        pixelValue: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    ) throws -> ScrollCapturer.BitmapData {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(rep.bitmapData)
        let bytesPerRow = rep.bytesPerRow
        let bytesPerPixel = rep.bitsPerPixel / 8

        for y in 0..<height {
            for x in 0..<width {
                let color = pixelValue(x, y)
                let offset = y * bytesPerRow + x * bytesPerPixel
                data[offset] = color.r
                data[offset + 1] = color.g
                data[offset + 2] = color.b
                data[offset + 3] = color.a
            }
        }

        return try XCTUnwrap(ScrollCapturer.BitmapData(rep: rep))
    }

    func testRefinedOverlapCorrectsNearbyRegistrationError() throws {
        let height = 80
        let trueOverlap = 54

        let previous = try makeBitmapData(width: 32, height: height) { _, row in
            let value = UInt8((row * 7) % 251)
            return (value, value, value, 255)
        }

        // Simulate a frame scrolled down by the true overlap. Vision may round
        // or slightly mis-register this translation; the local search should
        // recover the exact row boundary from two pixels away.
        let scrollShift = height - trueOverlap
        let current = try makeBitmapData(width: 32, height: height) { _, row in
            let sourceRow = row + scrollShift
            let value = UInt8((sourceRow * 7) % 251)
            return (value, value, value, 255)
        }

        XCTAssertEqual(
            ScrollStitchQuality.refinedOverlap(
                previous: previous,
                current: current,
                preliminary: trueOverlap - 2,
                searchRadius: 4
            ),
            trueOverlap
        )
    }

    func testRefinedOverlapKeepsVisionEstimateForFlatContent() throws {
        let width = 32
        let height = 80
        let previous = try makeBitmapData(width: width, height: height) { _, _ in
            (240, 240, 240, 255)
        }
        let current = try makeBitmapData(width: width, height: height) { _, _ in
            (240, 240, 240, 255)
        }

        XCTAssertEqual(
            ScrollStitchQuality.refinedOverlap(
                previous: previous,
                current: current,
                preliminary: 50,
                searchRadius: 4
            ),
            50
        )
    }

    func testSeamBlendProducesProgressiveTransition() throws {
        let width = 3
        let height = 12
        let source = try makeBitmapData(width: width, height: height) { _, row in
            row < 4 ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }
        let destination = try makeBitmapData(width: width, height: height) { _, _ in
            (0, 0, 0, 255)
        }

        ScrollStitchQuality.blendSeam(
            from: source,
            sourceStartRow: 4,
            rowCount: 8,
            to: destination,
            destinationStartRow: 4,
            blendRows: 4
        )

        var rowAverages: [Double] = []
        for row in 4..<8 {
            var total = 0
            for column in 0..<width {
                let pixel = destination.pixel(x: column, y: row)
                total += Int(pixel.r)
            }
            rowAverages.append(Double(total) / Double(width))
        }

        XCTAssertEqual(rowAverages[0], 51, accuracy: 1)
        XCTAssertEqual(rowAverages[1], 102, accuracy: 1)
        XCTAssertEqual(rowAverages[2], 153, accuracy: 1)
        XCTAssertEqual(rowAverages[3], 204, accuracy: 1)
        XCTAssertEqual(destination.pixel(x: 0, y: 2).r, 0)
    }
}
