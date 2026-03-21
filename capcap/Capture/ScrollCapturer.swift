import AppKit

class ScrollCapturer {
    private struct Strip {
        let frameIndex: Int
        let overlapPixels: Int
    }

    private var frames: [NSImage] = []
    private let captureRect: CGRect
    private let screen: NSScreen
    private var pendingCapture: DispatchWorkItem?
    private let maxFrames = 100

    init(rect: CGRect, screen: NSScreen) {
        self.captureRect = rect
        self.screen = screen

        if let image = ScreenCapturer.capture(rect: rect, screen: screen) {
            frames.append(image)
        }
    }

    func scheduleCapture() {
        pendingCapture?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.captureFrame()
        }

        pendingCapture = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func stopAndStitch() -> NSImage? {
        pendingCapture?.cancel()
        pendingCapture = nil

        captureFrame()

        guard !frames.isEmpty else { return nil }
        if frames.count == 1 { return frames[0] }

        return stitchFrames(frames)
    }

    private func captureFrame() {
        guard frames.count < maxFrames else { return }
        guard let image = ScreenCapturer.capture(rect: captureRect, screen: screen) else { return }

        if let previous = frames.last,
           imagesAreNearlyIdentical(previous, image) {
            return
        }

        frames.append(image)
    }

    private func stitchFrames(_ frames: [NSImage]) -> NSImage? {
        let bitmaps = frames.compactMap { bitmapData(from: $0) }
        guard bitmaps.count == frames.count, let firstFrame = frames.first else {
            return frames.first
        }

        let bitmapWidth = bitmaps[0].width
        let bitmapHeight = bitmaps[0].height
        let scale = CGFloat(bitmapHeight) / max(firstFrame.size.height, 1)
        let frameSize = firstFrame.size

        var strips: [Strip] = [Strip(frameIndex: 0, overlapPixels: 0)]

        for index in 1..<bitmaps.count {
            let overlap = findOverlap(
                previous: bitmaps[index - 1],
                current: bitmaps[index],
                width: bitmapWidth,
                height: bitmapHeight
            )

            let newContentPixels = bitmapHeight - overlap
            if newContentPixels < max(8, bitmapHeight / 200) {
                continue
            }

            strips.append(Strip(frameIndex: index, overlapPixels: overlap))
        }

        guard strips.count > 1 else { return frames.first }

        let totalHeightPixels = strips.reduce(bitmapHeight) { partialResult, strip in
            guard strip.frameIndex != 0 else { return partialResult }
            return partialResult + (bitmapHeight - strip.overlapPixels)
        }
        let totalHeightPoints = CGFloat(totalHeightPixels) / scale

        guard let stitchedBitmap = makeOutputBitmap(from: bitmaps[0], totalHeightPixels: totalHeightPixels) else {
            return frames.first
        }

        var destinationRow = 0

        for strip in strips {
            let bitmap = bitmaps[strip.frameIndex]
            let sourceStartRow = strip.frameIndex == 0 ? 0 : strip.overlapPixels
            let rowsToCopy = bitmapHeight - sourceStartRow

            copyRows(
                from: bitmap,
                sourceStartRow: sourceStartRow,
                rowCount: rowsToCopy,
                to: stitchedBitmap,
                destinationStartRow: destinationRow
            )

            destinationRow += rowsToCopy
        }

        stitchedBitmap.rep.size = NSSize(width: frameSize.width, height: totalHeightPoints)
        let image = NSImage(size: stitchedBitmap.rep.size)
        image.addRepresentation(stitchedBitmap.rep)
        return image
    }

    private func findOverlap(previous: BitmapData, current: BitmapData, width: Int, height: Int) -> Int {
        let sampleCols = stride(from: max(0, width / 8), to: width, by: max(1, width / 16)).map { $0 }
        let rowStep = max(1, height / 300)
        let minOverlap = max(12, height / 40)
        let maxSearchHeight = max(minOverlap, height - max(8, height / 200))

        var bestOverlap = 0
        var bestScore = Int.max

        for overlap in stride(from: maxSearchHeight, through: minOverlap, by: -1) {
            var diff = 0
            var comparisons = 0

            for row in stride(from: 0, to: overlap, by: rowStep) {
                let previousRow = height - overlap + row
                let currentRow = row

                for col in sampleCols {
                    diff += pixelDiff(previous.pixel(x: col, y: previousRow), current.pixel(x: col, y: currentRow))
                    comparisons += 1

                    if comparisons > 0, bestScore != Int.max, diff / comparisons > bestScore {
                        break
                    }
                }

                if comparisons > 0, bestScore != Int.max, diff / comparisons > bestScore {
                    break
                }
            }

            guard comparisons > 0 else { continue }
            let score = diff / comparisons

            if score < 8 {
                return overlap
            }

            if score < bestScore {
                bestScore = score
                bestOverlap = overlap
            }
        }

        return bestScore < 24 ? bestOverlap : 0
    }

    private func imagesAreNearlyIdentical(_ lhs: NSImage, _ rhs: NSImage) -> Bool {
        guard
            let left = bitmapData(from: lhs),
            let right = bitmapData(from: rhs),
            left.width == right.width,
            left.height == right.height
        else {
            return false
        }

        let sampleCols = stride(from: max(0, left.width / 8), to: left.width, by: max(1, left.width / 16))
        let sampleRows = stride(from: max(0, left.height / 8), to: left.height, by: max(1, left.height / 16))

        var diff = 0
        var comparisons = 0

        for row in sampleRows {
            for col in sampleCols {
                diff += pixelDiff(left.pixel(x: col, y: row), right.pixel(x: col, y: row))
                comparisons += 1
            }
        }

        guard comparisons > 0 else { return false }
        return diff / comparisons < 3
    }

    private func pixelDiff(_ lhs: (r: UInt8, g: UInt8, b: UInt8), _ rhs: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        abs(Int(lhs.r) - Int(rhs.r)) +
        abs(Int(lhs.g) - Int(rhs.g)) +
        abs(Int(lhs.b) - Int(rhs.b))
    }

    private final class BitmapData {
        let rep: NSBitmapImageRep
        let data: UnsafeMutablePointer<UInt8>
        let bytesPerRow: Int
        let width: Int
        let height: Int
        private let bytesPerPixel: Int

        init?(rep: NSBitmapImageRep) {
            guard let data = rep.bitmapData else { return nil }
            self.rep = rep
            self.data = data
            self.bytesPerRow = rep.bytesPerRow
            self.width = rep.pixelsWide
            self.height = rep.pixelsHigh
            self.bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        }

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else {
                return (0, 0, 0)
            }

            let offset = y * bytesPerRow + x * bytesPerPixel
            return (data[offset], data[offset + 1], data[offset + 2])
        }

        var bytesPerPixelValue: Int { bytesPerPixel }
    }

    private func bitmapData(from image: NSImage) -> BitmapData? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        return BitmapData(rep: rep)
    }

    private func makeOutputBitmap(from source: BitmapData, totalHeightPixels: Int) -> BitmapData? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.width,
            pixelsHigh: totalHeightPixels,
            bitsPerSample: source.rep.bitsPerSample,
            samplesPerPixel: source.rep.samplesPerPixel,
            hasAlpha: source.rep.hasAlpha,
            isPlanar: false,
            colorSpaceName: source.rep.colorSpaceName,
            bitmapFormat: source.rep.bitmapFormat,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        return BitmapData(rep: rep)
    }

    private func copyRows(
        from source: BitmapData,
        sourceStartRow: Int,
        rowCount: Int,
        to destination: BitmapData,
        destinationStartRow: Int
    ) {
        guard rowCount > 0 else { return }

        let bytesPerRow = min(source.width * source.bytesPerPixelValue, min(source.bytesPerRow, destination.bytesPerRow))

        for rowOffset in 0..<rowCount {
            let sourceOffset = (sourceStartRow + rowOffset) * source.bytesPerRow
            let destinationOffset = (destinationStartRow + rowOffset) * destination.bytesPerRow
            memcpy(destination.data.advanced(by: destinationOffset), source.data.advanced(by: sourceOffset), bytesPerRow)
        }
    }
}
