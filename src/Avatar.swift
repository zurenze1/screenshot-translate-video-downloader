// 小球换形象：选一张图片，自动抠出主体（人、宠物、物品），做成带白边的贴纸，代替圆球
import Cocoa
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

enum Avatar {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("桌面翻译器", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("小球形象.png")
    }()

    static var current: NSImage? {
        FileManager.default.fileExists(atPath: url.path) ? NSImage(contentsOf: url) : nil
    }

    static func reset() { try? FileManager.default.removeItem(at: url) }

    /// 生成贴纸：抠主体 → 外面描一圈白边 → 裁到刚好 → 缩到 512
    static func makeSticker(from cg: CGImage) -> (CGImage, Bool)? {
        let ctx = CIContext()
        let src = CIImage(cgImage: cg)
        var subject: CIImage?
        if #available(macOS 14.0, *) {
            let req = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            if (try? handler.perform([req])) != nil, let obs = req.results?.first, !obs.allInstances.isEmpty,
               let buf = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true) {
                subject = CIImage(cvPixelBuffer: buf)
            }
        }
        guard let fg = subject else {
            return circle(src, ctx).map { ($0, false) }
        }
        // 主体缩到 460 以内，留出白边的空间
        let scale = min(1, 460 / max(fg.extent.width, fg.extent.height))
        let small = fg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let pad: CGFloat = 26
        let moved = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX + pad, y: -small.extent.minY + pad))
        let canvas = CGRect(x: 0, y: 0, width: moved.extent.width + pad * 2, height: moved.extent.height + pad * 2)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        let base = moved.composited(over: clear)
        // 白边：把主体轮廓向外扩一圈，染成白色
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = base
        dilate.radius = 11
        let white = CIFilter.colorMatrix()
        white.inputImage = dilate.outputImage
        white.rVector = CIVector(x: 0, y: 0, z: 0, w: 0); white.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        white.bVector = CIVector(x: 0, y: 0, z: 0, w: 0); white.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        white.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        guard let outline = white.outputImage?.cropped(to: canvas) else { return nil }
        let blur = CIFilter.gaussianBlur()           // 让白边边缘柔和一点
        blur.inputImage = outline
        blur.radius = 1.2
        let soft = (blur.outputImage ?? outline).cropped(to: canvas)
        let sticker = base.composited(over: soft)
        return ctx.createCGImage(sticker, from: canvas).map { ($0, true) }
    }

    /// 没认出主体：裁成圆形头像
    private static func circle(_ src: CIImage, _ ctx: CIContext) -> CGImage? {
        guard let full = ctx.createCGImage(src, from: src.extent) else { return nil }
        let side = min(full.width, full.height)
        let crop = CGRect(x: (full.width - side) / 2, y: (full.height - side) / 2, width: side, height: side)
        guard let sq = full.cropping(to: crop) else { return nil }
        let S = 512
        guard let c = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: S, height: S)
        c.setFillColor(.white)
        c.fillEllipse(in: r)
        c.addEllipse(in: r.insetBy(dx: 18, dy: 18))
        c.clip()
        c.interpolationQuality = .high
        c.draw(sq, in: r.insetBy(dx: 18, dy: 18))
        return c.makeImage()
    }

    /// 选图 → 生成 → 保存
    static func choose(completion: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "选一张图片：会自动抠出里面的人物 / 宠物 / 物品，做成桌面小形象"
        guard p.runModal() == .OK, let u = p.url,
              let img = NSImage(contentsOf: u), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(false); return
        }
        Toast.show("正在生成形象…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = makeSticker(from: cg)
            DispatchQueue.main.async {
                guard let (out, cut) = r else { Toast.show("这张图片处理不了，换一张试试"); completion(false); return }
                let rep = NSBitmapImageRep(cgImage: out)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                Toast.show(cut ? "已换上新形象" : "没认出主体，已做成圆形头像")
                completion(true)
            }
        }
    }
}
