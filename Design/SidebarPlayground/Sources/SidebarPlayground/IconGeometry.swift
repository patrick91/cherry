import AppKit

/// Normalize the visible artwork, rather than assuming the image canvas is tight.
/// A high-resolution cached render also removes SF Symbols' alignment insets.
@MainActor
enum IconGeometry {
    static func normalized(_ source: NSImage) -> NSImage {
        let extent = 384
        guard source.size.width > 0, source.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: extent, pixelsHigh: extent,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: extent * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        let size = fitted(source.size, maximum: CGFloat(extent))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Avoid interpolation halos changing the measured artwork bounds.
        context.imageInterpolation = .none
        source.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let bounds = alphaBounds(bitmap), let cgImage = bitmap.cgImage?.cropping(to: bounds) else { return source }
        return NSImage(cgImage: cgImage, size: bounds.size)
    }

    static func fitted(_ size: CGSize, maximum: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = maximum / max(size.width, size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func alphaBounds(_ bitmap: NSBitmapImageRep) -> CGRect? {
        guard let bytes = bitmap.bitmapData, bitmap.samplesPerPixel == 4, !bitmap.isPlanar else { return nil }
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where bytes[y * bitmap.bytesPerRow + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
