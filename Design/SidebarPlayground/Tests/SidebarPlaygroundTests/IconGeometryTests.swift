import AppKit
import Testing
@testable import SidebarPlayground

@Test @MainActor func normalizationRemovesPaddingAndPreservesAspectRatio() throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 96, bitsPerPixel: 32))
    let bytes = try #require(bitmap.bitmapData)
    for i in 0..<(24 * 96) { bytes[i] = 0 }
    for y in 4..<20 {
        for x in 5..<13 {
            let index = y * 96 + x * 4
            bytes[index] = 255; bytes[index + 1] = 255; bytes[index + 2] = 255; bytes[index + 3] = 255
        }
    }
    #expect(IconGeometry.alphaBounds(bitmap) == CGRect(x: 5, y: 4, width: 8, height: 16))
    let source = NSImage(size: CGSize(width: 24, height: 24)); source.addRepresentation(bitmap)
    let result = IconGeometry.normalized(source)
    let size = IconGeometry.fitted(result.size, maximum: 16)
    #expect(abs(size.width - 8) < 0.2)
    #expect(size.height == 16)
    var rect = CGRect(origin: .zero, size: result.size)
    let cg = try #require(result.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    let normalized = NSBitmapImageRep(cgImage: cg)
    let bounds = try #require(IconGeometry.alphaBounds(normalized))
    #expect(bounds.minX == 0)
    #expect(bounds.minY == 0)
    #expect(bounds.width == CGFloat(cg.width))
    #expect(bounds.height == CGFloat(cg.height))
}
