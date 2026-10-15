// 生成「灵犀」图标：深夜蓝→紫的圆角方块，中间一颗发光的「灵犀一点」小球，外面一道光环
// 用法：swiftc make_icon.swift -o make_icon && ./make_icon 输出目录
import Cocoa

func draw(_ S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = NSGraphicsContext.current!.cgContext
    let u = S / 1024
    let cs = CGColorSpaceCreateDeviceRGB()
    func c(_ r: CGFloat, _ gg: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: gg, blue: b, alpha: a) }

    // 底板（macOS 标准尺寸：824 见方，圆角约 185）
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: c(0, 0, 0, 0.35))
    g.addPath(path); g.setFillColor(c(0.1, 0.1, 0.2)); g.fillPath()
    g.restoreGState()

    g.saveGState()
    g.addPath(path); g.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [c(0.07, 0.08, 0.22), c(0.22, 0.16, 0.55), c(0.50, 0.28, 0.86)] as CFArray,
                        locations: [0, 0.55, 1])!
    g.drawLinearGradient(bg, start: CGPoint(x: 200 * u, y: 100 * u), end: CGPoint(x: 830 * u, y: 924 * u), options: [])
    // 右上角柔光
    let glow = CGGradient(colorsSpace: cs, colors: [c(1.0, 0.55, 0.85, 0.45), c(1.0, 0.55, 0.85, 0)] as CFArray, locations: [0, 1])!
    g.drawRadialGradient(glow, startCenter: CGPoint(x: 820 * u, y: 860 * u), startRadius: 0,
                         endCenter: CGPoint(x: 820 * u, y: 860 * u), endRadius: 520 * u, options: [])
    // 中心蓝色光晕
    let center = CGPoint(x: 512 * u, y: 500 * u)
    let halo = CGGradient(colorsSpace: cs, colors: [c(0.35, 0.85, 1.0, 0.55), c(0.35, 0.85, 1.0, 0)] as CFArray, locations: [0, 1])!
    g.drawRadialGradient(halo, startCenter: center, startRadius: 0, endCenter: center, endRadius: 360 * u, options: [])

    // 倾斜的光环（后半段在球后面）
    // 整圈画在球后面；球前面那一段再补画一次（只画在球的范围内），两端不会有接缝
    func ring(front: Bool) {
        g.saveGState()
        if front {
            let R0: CGFloat = 165 * u
            g.addEllipse(in: CGRect(x: center.x - R0, y: center.y - R0, width: 2 * R0, height: 2 * R0)); g.clip()
        }
        g.translateBy(x: center.x, y: center.y)
        g.rotate(by: 0.42)
        let rr = CGRect(x: -310 * u, y: -92 * u, width: 620 * u, height: 184 * u)
        if front { g.clip(to: CGRect(x: -400 * u, y: -400 * u, width: 800 * u, height: 400 * u)) }
        g.addEllipse(in: rr)
        g.setLineWidth(22 * u)
        g.replacePathWithStrokedPath()
        g.clip()
        let rg = CGGradient(colorsSpace: cs, colors: [c(0.55, 0.95, 1.0, 1), c(1.0, 0.7, 0.95, 1)] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(rg, start: CGPoint(x: -310 * u, y: 0), end: CGPoint(x: 310 * u, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        g.restoreGState()
    }
    ring(front: false)

    // 发光小球
    let R: CGFloat = 165 * u
    g.saveGState()
    g.setShadow(offset: .zero, blur: 70 * u, color: c(0.5, 0.9, 1.0, 0.9))
    g.addEllipse(in: CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R))
    g.setFillColor(c(0.6, 0.9, 1.0)); g.fillPath()
    g.restoreGState()
    g.saveGState()
    g.addEllipse(in: CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R)); g.clip()
    let sphere = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1), c(0.62, 0.92, 1.0), c(0.30, 0.50, 0.98), c(0.36, 0.22, 0.78)] as CFArray,
                            locations: [0, 0.3, 0.75, 1])!
    let hl = CGPoint(x: center.x - 60 * u, y: center.y + 70 * u)
    g.drawRadialGradient(sphere, startCenter: hl, startRadius: 0, endCenter: center, endRadius: R, options: [.drawsAfterEndLocation])
    g.restoreGState()

    ring(front: true)

    // 一颗小星光（「一点通」）
    func sparkle(_ p: CGPoint, _ s: CGFloat, _ a: CGFloat) {
        let sp = CGMutablePath()
        sp.move(to: CGPoint(x: p.x, y: p.y + s))
        sp.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: CGPoint(x: p.x + s * 0.12, y: p.y + s * 0.12))
        sp.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: CGPoint(x: p.x + s * 0.12, y: p.y - s * 0.12))
        sp.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: CGPoint(x: p.x - s * 0.12, y: p.y - s * 0.12))
        sp.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: CGPoint(x: p.x - s * 0.12, y: p.y + s * 0.12))
        g.saveGState()
        g.setShadow(offset: .zero, blur: s * 0.6, color: c(1, 1, 1, 0.9))
        g.addPath(sp); g.setFillColor(c(1, 1, 1, a)); g.fillPath()
        g.restoreGState()
    }
    sparkle(CGPoint(x: 735 * u, y: 735 * u), 70 * u, 1)
    sparkle(CGPoint(x: 300 * u, y: 250 * u), 30 * u, 0.75)

    // 顶部一层玻璃反光
    let gloss = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.14), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(gloss, start: CGPoint(x: 0, y: 924 * u), end: CGPoint(x: 0, y: 600 * u), options: [])
    g.restoreGState()

    // 细边
    g.addPath(path); g.setStrokeColor(c(1, 1, 1, 0.12)); g.setLineWidth(2 * u); g.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
