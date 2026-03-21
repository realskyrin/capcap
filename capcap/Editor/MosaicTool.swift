import AppKit
import CoreImage

struct MosaicRegion {
    let rect: NSRect
    let pixelatedImage: NSImage
}

struct MosaicTool {
    static func createMosaicRegion(
        points: [NSPoint],
        brushRadius: CGFloat,
        imageSize: NSSize,
        baseImage: NSImage,
        blockSize: CGFloat = 12
    ) -> MosaicRegion? {
        guard !points.isEmpty else { return nil }

        // Calculate bounding rect of all brush points with padding
        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity

        for point in points {
            minX = min(minX, point.x - brushRadius)
            minY = min(minY, point.y - brushRadius)
            maxX = max(maxX, point.x + brushRadius)
            maxY = max(maxY, point.y + brushRadius)
        }

        // Clamp to image bounds
        minX = max(0, minX)
        minY = max(0, minY)
        maxX = min(imageSize.width, maxX)
        maxY = min(imageSize.height, maxY)

        let regionRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard regionRect.width > 0, regionRect.height > 0 else { return nil }

        // Extract the sub-image for this region
        guard let cgImage = baseImage.cgImagePreservingBacking() else { return nil }

        // Convert to CG coordinates (flip Y)
        let scale = CGFloat(cgImage.width) / imageSize.width
        let cgRegion = CGRect(
            x: regionRect.origin.x * scale,
            y: (imageSize.height - regionRect.origin.y - regionRect.height) * scale,
            width: regionRect.width * scale,
            height: regionRect.height * scale
        )

        guard let croppedCG = cgImage.cropping(to: cgRegion) else { return nil }

        // Apply pixelation using CIFilter
        let ciImage = CIImage(cgImage: croppedCG)
        let pixelateFilter = CIFilter(name: "CIPixellate")!
        pixelateFilter.setValue(ciImage, forKey: kCIInputImageKey)
        pixelateFilter.setValue(max(blockSize, 4), forKey: kCIInputScaleKey)
        pixelateFilter.setValue(CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY), forKey: kCIInputCenterKey)

        guard let outputCI = pixelateFilter.outputImage else { return nil }

        let context = CIContext()
        guard let outputCG = context.createCGImage(outputCI, from: ciImage.extent) else { return nil }

        let pixelatedImage = NSImage(cgImage: outputCG, size: regionRect.size)
        return MosaicRegion(rect: regionRect, pixelatedImage: pixelatedImage)
    }
}
