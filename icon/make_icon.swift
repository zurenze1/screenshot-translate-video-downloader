// Cream / champagne icon, matching the product page and native floating toolbox.
// swiftc make_icon.swift -o make_icon && ./make_icon AppIcon.iconset
import Cocoa

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = NSGraphicsContext.current!.cgContext
    let u = size / 1024
    func c(_ r: CGFloat, _ gg: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: gg, blue: b, alpha: a) }
    let space = CGColorSpaceCreateDeviceRGB()
    g.scaleBy(x: u, y: u)
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: c(0.28, 0.22, 0.12, 0.22))
    g.addPath(body); g.setFillColor(c(0.90, 0.85, 0.73)); g.fillPath()
    g.restoreGState()
    g.saveGState(); g.addPath(body); g.clip()
    let paper = CGGradient(colorsSpace: space, colors: [c(1, 0.99, 0.95), c(0.95, 0.92, 0.85), c(0.86, 0.81, 0.70)] as CFArray, locations: [0, 0.6, 1])!
    g.drawLinearGradient(paper, start: CGPoint(x: 240, y: 910), end: CGPoint(x: 830, y: 110), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let seam = CGPath(roundedRect: CGRect(x: 136, y: 136, width: 752, height: 752), cornerWidth: 155, cornerHeight: 155, transform: nil)
    g.addPath(seam); g.setStrokeColor(c(1, 1, 0.98, 0.65)); g.setLineWidth(2); g.strokePath()
    let corners = CGMutablePath()
    for (x, y, dx, dy) in [(300.0, 300.0, 1.0, 1.0), (724, 300, -1, 1), (724, 724, -1, -1), (300, 724, 1, -1)] {
        corners.move(to: CGPoint(x: x, y: y + dy * 99))
        corners.addLine(to: CGPoint(x: x, y: y))
        corners.addLine(to: CGPoint(x: x + dx * 99, y: y))
    }
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -4), blur: 5, color: c(0.38, 0.27, 0.09, 0.25))
    g.addPath(corners); g.setStrokeColor(c(0.61, 0.49, 0.27)); g.setLineWidth(27); g.setLineJoin(.round); g.setLineCap(.round); g.strokePath()
    g.restoreGState()
    g.saveGState()
    g.addPath(corners); g.setLineWidth(22); g.setLineJoin(.round); g.setLineCap(.round); g.replacePathWithStrokedPath(); g.clip()
    let gold = CGGradient(colorsSpace: space, colors: [c(0.52, 0.40, 0.20), c(0.80, 0.69, 0.43), c(0.95, 0.87, 0.66), c(0.53, 0.42, 0.23)] as CFArray, locations: [0, 0.35, 0.6, 1])!
    g.drawLinearGradient(gold, start: CGPoint(x: 260, y: 240), end: CGPoint(x: 760, y: 820), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    g.restoreGState()
    let play = CGMutablePath()
    play.move(to: CGPoint(x: 459, y: 410)); play.addLine(to: CGPoint(x: 621, y: 512)); play.addLine(to: CGPoint(x: 459, y: 614)); play.closeSubpath()
    g.saveGState(); g.setShadow(offset: CGSize(width: 0, height: -6), blur: 7, color: c(0.37, 0.28, 0.12, 0.22))
    g.addPath(play); g.setFillColor(c(0.64, 0.52, 0.30)); g.fillPath(); g.restoreGState()
    g.addPath(play); g.clip()
    g.drawLinearGradient(gold, start: CGPoint(x: 400, y: 420), end: CGPoint(x: 620, y: 660), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    g.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    }
}
