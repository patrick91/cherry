// Regenerate with: swift Design/SessionsIcon/render.swift
// Native vector counterpart of source.svg, rendered directly at every icon size.
import AppKit
import CoreGraphics
import Foundation

let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = output.appendingPathComponent("AppIconSessions.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    let rgb = UInt32(hex, radix: 16)!
    return CGColor(red: CGFloat((rgb >> 16) & 255) / 255,
                   green: CGFloat((rgb >> 8) & 255) / 255,
                   blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}
func draw(size: Int) throws -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }
    func slab(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat,
              _ first: String, _ last: String, _ skew: CGFloat, shadow: Bool = false) {
        let path = rect(x, y, w, h, r)
        if shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 22), blur: 46, color: color("030C30", 0.42))
            context.addPath(path)
            context.setFillColor(color(first))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(first), color(last)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: x, y: y), end: CGPoint(x: x + w * skew, y: y + h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
    func outline(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ hex: String, _ alpha: CGFloat, _ width: CGFloat = 3) {
        context.addPath(rect(x, y, w, h, r))
        context.setStrokeColor(color(hex, alpha))
        context.setLineWidth(width)
        context.strokePath()
    }
    func line(_ pts: [(CGFloat, CGFloat)], _ hex: String, _ width: CGFloat, _ alpha: CGFloat = 1) {
        context.beginPath()
        context.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for p in pts.dropFirst() { context.addLine(to: CGPoint(x: p.0, y: p.1)) }
        context.setStrokeColor(color(hex, alpha))
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: String, _ alpha: CGFloat = 1) {
        context.setFillColor(color(hex, alpha))
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    slab(96, 96, 832, 832, 184, "334A91", "121A41", 0.8)
    outline(98, 98, 828, 828, 182, "93B3FF", 0.3)
    slab(200, 236, 534, 354, 44, "98E7D5", "47B8C2", 0.4, shadow: true)
    outline(202, 238, 530, 350, 42, "E5FFEE", 0.68)
    line([(202,312), (732,312)], "103E57", 3, 0.2)
    for x: CGFloat in [242, 273, 304] { circle(x, 274, 9, "164C64", 0.45) }
    line([(252,363), (276,387), (252,411)], "164760", 16)
    line([(298,414), (335,414)], "164760", 16)
    slab(306, 422, 534, 354, 44, "DCFFF0", "71E0D6", 0.6, shadow: true)
    outline(308, 424, 530, 350, 42, "F3FFF5", 0.85)
    line([(308,498), (838,498)], "19526B", 3, 0.17)
    for x: CGFloat in [348, 379, 410] { circle(x, 460, 9, "1A596A", 0.43) }
    line([(368,555), (406,593), (368,631)], "174157", 21)
    line([(443,637), (497,637)], "174157", 21)
    circle(777, 713, 27, "E5AA4E")
    context.addEllipse(in: CGRect(x: 750, y: 686, width: 54, height: 54))
    context.setStrokeColor(color("FFF3CE"))
    context.setLineWidth(4)
    context.strokePath()
    let representation = NSBitmapImageRep(cgImage: context.makeImage()!)
    return representation.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try draw(size: base * scale).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
try draw(size: 1024).write(to: output.appendingPathComponent("AppIconSessions.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", output.appendingPathComponent("AppIconSessions.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    fputs("iconutil failed; generated PNGs are available in AppIconSessions.iconset.\n", stderr)
    exit(process.terminationStatus)
}
