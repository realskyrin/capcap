import CoreGraphics
import Foundation

/// Identifies a narrow, bordered vertical scrollbar at the capture's right edge.
/// It never invents pixels. Callers may crop the returned backing-pixel inset
/// from their result, and retain the largest verified inset for later frames.
enum ScrollCaptureChrome {
    /// A verified downward document movement makes a scrollbar thumb move down,
    /// while the document itself moves up. A stationary line, text, or a blank
    /// margin alone does not authorize a crop. Overlay / borderless scrollbars
    /// deliberately return zero because their content boundary is not proven.
    static func contentRightInset(
        previous: CGImage, current: CGImage, shift: Int, scale: CGFloat
    ) -> Int {
        guard previous.width == current.width, previous.height == current.height,
              shift > 0, shift < previous.height, scale.isFinite,
              scale >= 1, scale <= 4 else { return 0 }

        let minimumInset = max(8, Int((8 * scale).rounded(.up)))
        let maximumInset = min(Int((24 * scale).rounded(.up)), previous.width / 8)
        guard maximumInset >= minimumInset,
              previous.height >= Int((80 * scale).rounded(.up)),
              let before = Strip(previous, width: maximumInset + 1),
              let after = Strip(current, width: maximumInset + 1) else { return 0 }

        var best: (inset: Int, score: Double)?
        for inset in minimumInset...maximumInset {
            let boundary = before.width - inset
            var supported = [Bool](repeating: false, count: before.height)
            var positive = 0
            var negative = 0
            var strength = 0
            for y in 0..<before.height {
                let oldEdge = before[boundary, y] - before[boundary - 1, y]
                let newEdge = after[boundary, y] - after[boundary - 1, y]
                guard abs(oldEdge) >= 8, abs(newEdge) >= 8,
                      oldEdge * newEdge > 0,
                      abs(before[boundary, y] - after[boundary, y]) <= 3,
                      abs(before[boundary - 1, y] - after[boundary - 1, y]) <= 3 else { continue }
                supported[y] = true
                if oldEdge > 0 { positive += 1 } else { negative += 1 }
                strength += min(abs(oldEdge), abs(newEdge))
            }
            let support = positive + negative
            // A track edge extends through most of the selected viewport. The
            // thumb's own short vertical edges cannot pass this requirement.
            guard support * 100 >= before.height * 65,
                  max(positive, negative) * 100 >= support * 90 else { continue }

            let center = (boundary + inset / 3)..<(boundary + inset * 4 / 5)
            let left = (boundary + max(1, inset / 12))..<(boundary + inset / 5)
            let right = (boundary + inset * 5 / 6)..<(boundary + inset * 14 / 15)
            guard !center.isEmpty, !left.isEmpty, !right.isEmpty,
                  let oldThumb = thumb(in: before, center: center, left: left, right: right,
                                       supported: supported, scale: scale),
                  let newThumb = thumb(in: after, center: center, left: left, right: right,
                                       supported: supported, scale: scale),
                  oldThumb.polarity == newThumb.polarity else { continue }

            let lengthTolerance = max(Int((3 * scale).rounded(.up)), oldThumb.rows.count / 12)
            let movement = newThumb.rows.lowerBound - oldThumb.rows.lowerBound
            guard abs(oldThumb.rows.count - newThumb.rows.count) <= lengthTolerance,
                  movement >= max(2, Int(scale.rounded(.up))),
                  movement <= Int((Double(shift) * 0.85).rounded(.up)) + Int(scale.rounded(.up)),
                  abs(oldThumb.contrast - newThumb.contrast) <= max(12, oldThumb.contrast / 4)
            else { continue }

            var stationary = 0
            var inspected = 0
            for y in 0..<before.height where supported[y] {
                let inThumb = oldThumb.rows.contains(y) || newThumb.rows.contains(y)
                var difference = 0
                var samples = 0
                for x in boundary..<(before.width) {
                    if inThumb, center.contains(x) { continue }
                    // The rounded cap extends outside the central flat part.
                    if inThumb, x >= left.upperBound, x < right.lowerBound { continue }
                    difference += abs(before[x, y] - after[x, y])
                    samples += 1
                }
                guard samples > 0 else { continue }
                inspected += 1
                if difference <= samples * 3 { stationary += 1 }
            }
            guard inspected > 0, stationary * 100 >= inspected * 94 else { continue }

            let score = Double(strength) / Double(before.height)
            if best == nil || score > best!.score { best = (inset, score) }
        }
        return best?.inset ?? 0
    }

    private struct Thumb {
        let rows: Range<Int>
        let polarity: Int
        let contrast: Int
    }

    private static func thumb(
        in strip: Strip, center: Range<Int>, left: Range<Int>, right: Range<Int>,
        supported: [Bool], scale: CGFloat
    ) -> Thumb? {
        var contrasts = [Int](repeating: 0, count: strip.height)
        for y in 0..<strip.height where supported[y] {
            let leftMean = left.reduce(0) { $0 + strip[$1, y] } / left.count
            let rightMean = right.reduce(0) { $0 + strip[$1, y] } / right.count
            guard abs(leftMean - rightMean) <= 10 else { continue }
            var minimum = 255
            var maximum = 0
            var total = 0
            for x in center {
                let value = strip[x, y]
                minimum = min(minimum, value)
                maximum = max(maximum, value)
                total += value
            }
            // Text has strokes and gaps; the interior of a thumb is flat.
            guard maximum - minimum <= 10 else { continue }
            let contrast = total / center.count - (leftMean + rightMean) / 2
            if abs(contrast) >= 14 { contrasts[y] = contrast }
        }

        var candidates: [Thumb] = []
        for polarity in [-1, 1] {
            var start: Int?
            var total = 0
            var count = 0
            for y in 0...strip.height {
                let value = y < strip.height ? contrasts[y] * polarity : 0
                if value > 0 {
                    if start == nil { start = y }
                    total += value
                    count += 1
                } else if let first = start {
                    candidates.append(Thumb(rows: first..<y, polarity: polarity, contrast: total / count))
                    start = nil
                    total = 0
                    count = 0
                }
            }
        }
        guard let longest = candidates.max(by: { $0.rows.count < $1.rows.count }),
              longest.rows.count >= max(Int((20 * scale).rounded(.up)), strip.height / 20),
              longest.rows.count * 4 <= strip.height * 3 else { return nil }
        let otherRows = candidates.reduce(0) { $0 + $1.rows.count } - longest.rows.count
        guard otherRows <= max(Int((4 * scale).rounded(.up)), longest.rows.count / 12) else { return nil }
        return longest
    }

    private struct Strip {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        subscript(x: Int, y: Int) -> Int { Int(pixels[y * width + x]) }

        init?(_ image: CGImage, width: Int) {
            guard image.width >= width, let crop = image.cropping(to: CGRect(
                x: image.width - width, y: 0, width: width, height: image.height
            )) else { return nil }
            var bytes = [UInt8](repeating: 255, count: width * image.height)
            let success = bytes.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(
                    data: storage.baseAddress, width: width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: image.height))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: image.height))
                return true
            }
            guard success else { return nil }
            self.width = width
            height = image.height
            pixels = bytes
        }
    }
}
