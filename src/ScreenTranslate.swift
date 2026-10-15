// 全屏翻译：桌面小圆球，点一下把屏幕上的外文都盖上中文，再点一下恢复原文
import Cocoa
import Vision
import ScreenCaptureKit
import Carbon

// MARK: - 识别结果

struct TextBlock {
    var rect: CGRect      // 像素坐标，原点在左下
    var lastLine: CGRect
    var text: String
    var lines: Int
}

enum BlockOCR {
    /// 只识别 roi（像素，左下原点）里的文字；切成几段并行识别，加快速度，精度保持 .accurate
    static func lines(in cg: CGImage, roi: CGRect) async -> [(CGRect, String)] {
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        let roi = roi.intersection(full)
        guard roi.width > 4, roi.height > 4 else { return [] }
        let count = max(1, min(4, Int((roi.height / 520).rounded(.up))))
        let overlap: CGFloat = 140
        let bandH = count == 1 ? roi.height : (roi.height + overlap * CGFloat(count - 1)) / CGFloat(count)
        var bands: [CGRect] = []
        for i in 0..<count {
            let y = roi.minY + CGFloat(i) * (bandH - overlap)
            bands.append(CGRect(x: roi.minX, y: y, width: roi.width, height: min(bandH, roi.maxY - y)))
        }
        let all: [(CGRect, String, Float)] = await withTaskGroup(of: [(CGRect, String, Float)].self) { g in
            for (i, b) in bands.enumerated() {
                let last = bands.count - 1
                g.addTask {
                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .accurate
                    req.usesLanguageCorrection = true
                    req.automaticallyDetectsLanguage = true
                    req.regionOfInterest = CGRect(x: b.minX / W, y: b.minY / H, width: b.width / W, height: b.height / H)
                    req.minimumTextHeight = Float(min(1, 10 / b.height))
                    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
                    var out: [(CGRect, String, Float)] = []
                    for o in req.results ?? [] {
                        guard let c = o.topCandidates(1).first, c.confidence >= 0.5 else { continue }
                        let bb = o.boundingBox
                        let r = CGRect(x: b.minX + bb.minX * b.width, y: b.minY + bb.minY * b.height,
                                       width: bb.width * b.width, height: bb.height * b.height)
                        // 被分段边界切断的行丢掉，它完整地出现在相邻那段里
                        if i > 0 && r.minY < b.minY + 3 { continue }
                        if i < last && r.maxY > b.maxY - 3 { continue }
                        out.append((r, c.string, c.confidence))
                    }
                    return out
                }
            }
            var acc: [(CGRect, String, Float)] = []
            for await part in g { acc += part }
            return acc
        }
        // 重叠区里重复识别的行只留一条
        var kept: [(CGRect, String, Float)] = []
        for item in all.sorted(by: { $0.2 > $1.2 }) {
            let dup = kept.contains { k in
                let inter = k.0.intersection(item.0)
                return !inter.isNull && inter.width * inter.height > 0.5 * min(k.0.width * k.0.height, item.0.width * item.0.height)
            }
            if !dup { kept.append(item) }
        }
        return kept.map { ($0.0, $0.1) }
    }

    /// 把上下相邻、对齐的行合成一段，整段翻译更通顺
    static func group(_ lines: [(CGRect, String)]) -> [TextBlock] {
        let sorted = lines.sorted { $0.0.maxY > $1.0.maxY }
        var blocks: [TextBlock] = []
        for (r, t) in sorted {
            var attached = false
            for i in blocks.indices.reversed() {
                let last = blocks[i].lastLine
                let h = max(last.height, r.height)
                let gap = last.minY - r.maxY
                guard gap > -h * 0.3, gap < h * 0.8 else { continue }
                let ratio = max(last.height, r.height) / max(1, min(last.height, r.height))
                guard ratio < 1.45 else { continue }
                let overlap = min(last.maxX, r.maxX) - max(last.minX, r.minX)
                let leftAligned = abs(last.minX - r.minX) < h * 1.2
                guard leftAligned || overlap > min(last.width, r.width) * 0.6 else { continue }
                var text = blocks[i].text
                if text.hasSuffix("-") { text.removeLast() }
                else if let a = text.last, let b = t.first, !(isCJK(a) && isCJK(b)) { text += " " }
                text += t
                blocks[i].text = text
                blocks[i].rect = blocks[i].rect.union(r)
                blocks[i].lastLine = r
                blocks[i].lines += 1
                attached = true
                break
            }
            if !attached { blocks.append(TextBlock(rect: r, lastLine: r, text: t, lines: 1)) }
        }
        return blocks
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(u) || (0x4E00...0x9FFF).contains(u) || (0xAC00...0xD7AF).contains(u)
    }

    /// 已经是简体中文、纯数字符号的不翻
    static func needsTranslation(_ s: String) -> Bool {
        var letters = 0, han = 0, kana = 0
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) { han += 1 }
            else if (0x3040...0x30FF).contains(u.value) { kana += 1 }
            else if CharacterSet.letters.contains(u) { letters += 1 }
        }
        if kana > 0 { return true }                 // 日文
        if han > 0 && han * 3 >= letters { return false }
        return letters >= 2
    }
}

// MARK: - 截屏像素

final class PixelSampler {
    let w: Int, h: Int
    private let ctx: CGContext
    private let ptr: UnsafeMutablePointer<UInt8>

    init?(_ cg: CGImage) {
        let w = cg.width, h = cg.height
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let d = c.data else { return nil }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.w = w; self.h = h; ctx = c
        ptr = d.assumingMemoryBound(to: UInt8.self)
    }

    /// x, y 为左下原点的像素坐标
    func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
        let xx = min(max(x, 0), w - 1)
        let row = min(max(h - 1 - y, 0), h - 1)
        let i = (row * w + xx) * 4
        return (CGFloat(ptr[i]) / 255, CGFloat(ptr[i + 1]) / 255, CGFloat(ptr[i + 2]) / 255)
    }

    static func lum(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat { 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2 }

    static let gx = 160, gy = 100

    /// 指纹：把屏幕分成 160×100 格，每格取 9 个点的平均亮度
    func fingerprint() -> [UInt8] {
        let gx = PixelSampler.gx, gy = PixelSampler.gy
        var out = [UInt8](repeating: 0, count: gx * gy)
        let cw = max(1, w / gx), ch = max(1, h / gy)
        for j in 0..<gy {
            for i in 0..<gx {
                var sum: CGFloat = 0
                for dy in 0..<3 { for dx in 0..<3 {
                    sum += PixelSampler.lum(rgb(i * cw + (dx * 2 + 1) * cw / 6, j * ch + (dy * 2 + 1) * ch / 6))
                } }
                out[j * gx + i] = UInt8(min(255, sum / 9 * 255))
            }
        }
        return out
    }

    /// 和上一帧比，变化的像素行范围（左下原点）；没有上一帧就是整屏
    func changedRows(_ a: [UInt8], _ prev: [UInt8]) -> (CGFloat, CGFloat)? {
        let gx = PixelSampler.gx, gy = PixelSampler.gy
        guard prev.count == a.count else { return (0, CGFloat(h)) }
        var lo = -1, hi = -1
        for j in 0..<gy {
            for i in 0..<gx where abs(Int(a[j * gx + i]) - Int(prev[j * gx + i])) > 6 {
                if lo < 0 { lo = j }
                hi = j
                break
            }
        }
        guard lo >= 0 else { return nil }
        let ch = CGFloat(h) / CGFloat(gy)
        return (CGFloat(lo) * ch, CGFloat(hi + 1) * ch)
    }

    /// 取文字块四周的颜色当底色，再选对比度高的字色
    func colors(around r: CGRect) -> (NSColor, NSColor) {
        let pad: CGFloat = 3
        let e = r.insetBy(dx: -pad, dy: -pad)
        var samples: [(CGFloat, CGFloat, CGFloat)] = []
        let xs = [e.minX, e.minX + e.width * 0.25, e.midX, e.minX + e.width * 0.75, e.maxX]
        for x in xs { samples.append(rgb(Int(x), Int(e.minY))); samples.append(rgb(Int(x), Int(e.maxY))) }
        samples.append(rgb(Int(e.minX), Int(e.midY)))
        samples.append(rgb(Int(e.maxX), Int(e.midY)))
        samples.sort { PixelSampler.lum($0) < PixelSampler.lum($1) }
        let m = samples[samples.count / 2]
        let bg = NSColor(srgbRed: m.0, green: m.1, blue: m.2, alpha: 1)
        let fg: NSColor = PixelSampler.lum(m) > 0.55 ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        return (bg, fg)
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var n = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 10 { n += 1 }
        return Double(n) / Double(a.count)
    }
}

// MARK: - 隐私：这些窗口不截、不识别、不翻译

struct WinInfo {
    let id: CGWindowID
    let bounds: CGRect      // 全局坐标（点），原点在主屏左上
    let layer: Int
    let alpha: Double
    let mine: Bool
    let isPrivate: Bool
}

enum Privacy {
    /// 聊天、邮件、密码类软件
    static let bundleIDs: Set<String> = [
        "com.tencent.xinWeChat", "com.tencent.qq", "com.tencent.QQ", "com.tencent.WeWorkMac", "com.tencent.tim",
        "com.alibaba.DingTalkMac",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "jp.naver.line.mac", "com.skype.skype",
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.tencent.Foxmail",
        "com.netease.macmail", "com.netease.mailmaster", "it.bloop.airmail2", "org.mozilla.thunderbird",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]
    static let appNames: Set<String> = [
        "微信", "WeChat", "QQ", "TIM", "企业微信", "WeCom", "钉钉", "DingTalk",
        "Telegram", "WhatsApp", "信息", "Messages", "Slack", "Discord", "LINE", "Skype",
        "邮件", "Mail", "Outlook", "Microsoft Outlook", "Foxmail", "Spark", "Spark Desktop", "网易邮箱大师",
        "Airmail", "Thunderbird", "钥匙串访问", "Keychain Access", "密码", "Passwords", "1Password", "1Password 7", "Bitwarden",
    ]
    /// 浏览器里的网页邮箱、网页版聊天
    static let titleKeywords = [
        "Gmail", "Outlook", "Hotmail", "QQ邮箱", "QQ Mail", "163邮箱", "126邮箱", "网易邮箱", "新浪邮箱", "阿里邮箱",
        "企业邮箱", "iCloud Mail", "Yahoo Mail", "Proton Mail", "Zoho Mail",
        "@gmail.com", "@qq.com", "@163.com", "@126.com", "@outlook.com", "@hotmail.com", "@icloud.com", "@foxmail.com",
        "微信", "WeChat", "WhatsApp", "Telegram", "Messenger", "邮箱", "密码", "Password",
    ]
    private static var pidCache: [pid_t: Bool] = [:]
    private static let lock = NSLock()

    static func isPrivateApp(pid: pid_t, name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let c = pidCache[pid] { return c }
        let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let r = bundleIDs.contains(bid) || appNames.contains(name)
            || bid.hasPrefix("com.tencent.xin") || bid.hasPrefix("com.tencent.qq")
        pidCache[pid] = r
        return r
    }

    static func titleIsPrivate(_ t: String) -> Bool {
        guard !t.isEmpty else { return false }
        return titleKeywords.contains { t.localizedCaseInsensitiveContains($0) }
    }

    /// 屏幕上所有窗口，从最前到最后
    static func windows() -> [WinInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return nil }
            let layer = d[kCGWindowLayer as String] as? Int ?? 0
            let alpha = d[kCGWindowAlpha as String] as? Double ?? 1
            if pid == me { return WinInfo(id: id, bounds: b, layer: layer, alpha: alpha, mine: true, isPrivate: false) }
            let owner = d[kCGWindowOwnerName as String] as? String ?? ""
            let title = d[kCGWindowName as String] as? String ?? ""
            let priv = isPrivateApp(pid: pid, name: owner) || titleIsPrivate(title)
            return WinInfo(id: id, bounds: b, layer: layer, alpha: alpha, mine: false, isPrivate: priv)
        }
    }

    /// 这个点上最前面的窗口是不是私密窗口
    static func isPrivate(at p: CGPoint, _ wins: [WinInfo]) -> Bool {
        for w in wins where !w.mine && w.alpha > 0.05 && w.layer < 25 {
            if w.bounds.contains(p) { return w.isPrivate }
        }
        return false
    }
}

// MARK: - 截屏（不截自己的窗口和私密窗口）

@available(macOS 14.0, *)
final class ScreenGrabber {
    private var content: SCShareableContent?
    private var ids: Set<CGWindowID> = []

    func capture(displayID: CGDirectDisplayID, scale: CGFloat, wins: [WinInfo]) async throws -> (CGImage, CGRect) {
        let now = Set(wins.map { $0.id })
        if content == nil || now != ids {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            ids = now
        }
        guard let content = content,
              let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw TError(message: "找不到屏幕")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let hide = Set(wins.filter { $0.mine || $0.isPrivate }.map { $0.id })
        let excluded = content.windows.filter { hide.contains($0.windowID) || $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return (img, display.frame)
    }
}

// MARK: - 覆盖层

struct OverlayItem {
    let rect: CGRect   // 视图坐标（点）
    let text: String
    let bg: NSColor
    let fg: NSColor
    let lines: Int
}

final class OverlayView: NSView {
    var items: [OverlayItem] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 0
        for it in items {
            let r = it.rect.insetBy(dx: -3, dy: -2)
            it.bg.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            let lineH = it.rect.height / CGFloat(max(it.lines, 1))
            var size = min(max(lineH * 0.8, 9), 40)
            var attrs: [NSAttributedString.Key: Any] = [:]
            var b = CGRect.zero
            let s = it.text as NSString
            while true {
                attrs = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: it.fg, .paragraphStyle: para]
                b = s.boundingRect(with: NSSize(width: r.width, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin], attributes: attrs)
                if b.height <= r.height + 1 || size <= 8 { break }
                size -= 0.5
            }
            let h = min(b.height, r.height + size * 0.5)
            let y = r.minY + max(0, (r.height - h) / 2)
            s.draw(with: NSRect(x: r.minX, y: y, width: r.width, height: h),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }
}

// MARK: - 桌面小圆球

final class OrbView: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }
    var busy = false { didSet { busy ? startSpin() : stopSpin() } }
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onMoved: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var onDropLink: ((String) -> Void)?
    var badge = 0 { didSet { needsDisplay = true } }
    /// 自定义形象（贴纸）；为空时画默认圆球
    var avatar: NSImage? { didSet { needsDisplay = true } }
    private var downPoint: NSPoint?
    private var winOrigin: NSPoint = .zero
    private var dragged = false
    private var angle: CGFloat = 0
    private var spinTimer: Timer?
    private var hover = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func drawAvatar(_ img: NSImage) {
        let area = bounds.insetBy(dx: 4, dy: 4)
        let s = min(area.width / img.size.width, area.height / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        let r = NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.35)
        sh.shadowBlurRadius = 4
        sh.shadowOffset = NSSize(width: 0, height: -1.5)
        sh.set()
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // 状态小角标：整屏翻译开着 = 蓝色「中」
        if isOn || busy || failed {
            let d: CGFloat = 20
            let c = NSRect(x: bounds.maxX - d - 1, y: bounds.minY + 1, width: d, height: d)
            (failed ? NSColor.systemRed : ProductTheme.gold).setFill()
            NSBezierPath(ovalIn: c).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: c.insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 1.5; ring.stroke()
            if busy {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: c.midX, y: c.midY), radius: d / 2 - 4, startAngle: angle, endAngle: angle + 250)
                arc.lineWidth = 2; arc.lineCapStyle = .round; arc.stroke()
            } else {
                let t = (failed ? "!" : "中") as NSString
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
                let sz = t.size(withAttributes: a)
                t.draw(at: NSPoint(x: c.midX - sz.width / 2, y: c.midY - sz.height / 2), withAttributes: a)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let img = avatar {
            drawAvatar(img)
            drawBadge()
            return
        }
        let r = bounds.insetBy(dx: 4, dy: 4)
        let capsule = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        NSGradient(starting: ProductTheme.surface, ending: ProductTheme.paper)?.draw(in: capsule, angle: -80)
        (hover ? ProductTheme.gold.withAlphaComponent(0.85) : ProductTheme.line).setStroke()
        capsule.lineWidth = hover ? 1.3 : 0.8; capsule.stroke()
        ProductTheme.drawMark(in: NSRect(x: 12, y: bounds.midY - 16, width: 32, height: 32))
        let title = isOn ? "中文已开" : "工具面板"
        (title as NSString).draw(at: NSPoint(x: 51, y: bounds.midY + 1), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: ProductTheme.ink])
        ((busy ? "正在翻译…" : "译 · 截 · 存") as NSString).draw(at: NSPoint(x: 51, y: bounds.midY - 13), withAttributes: [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: ProductTheme.muted])
        if busy || isOn || failed {
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: 28, y: bounds.midY), radius: 17.5, startAngle: busy ? angle : 0, endAngle: busy ? angle + 105 : 360)
            (failed ? NSColor.systemRed : ProductTheme.gold).setStroke()
            ring.lineWidth = 1.5; ring.lineCapStyle = .round; ring.stroke()
        }
        drawBadge()
    }

    private func drawBadge() {
        if badge > 0 {
            let t = badge > 99 ? "99+" : "\(badge)"
            let ba: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
            let ts = (t as NSString).size(withAttributes: ba)
            let bw = max(17, ts.width + 8)
            let br = NSRect(x: bounds.maxX - bw - 1, y: bounds.maxY - 18, width: bw, height: 17)
            ProductTheme.gold.setFill()
            NSBezierPath(roundedRect: br, xRadius: 8.5, yRadius: 8.5).fill()
            (t as NSString).draw(at: NSPoint(x: br.midX - ts.width / 2, y: br.midY - ts.height / 2), withAttributes: ba)
        }
    }

    private func startSpin() {
        guard spinTimer == nil else { return }
        spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.angle -= 12
            self.needsDisplay = true
        }
    }

    private func stopSpin() {
        spinTimer?.invalidate(); spinTimer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = NSEvent.mouseLocation
        winOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downPoint, let w = window else { return }
        let p = NSEvent.mouseLocation
        if !dragged && hypot(p.x - d.x, p.y - d.y) < 4 { return }
        dragged = true
        w.setFrameOrigin(NSPoint(x: winOrigin.x + p.x - d.x, y: winOrigin.y + p.y - d.y))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
        downPoint = nil
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }

    // 把图片拖到小球上，存进截图中转站
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource is ShelfController ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty {
            // 拖进来的是网页链接或带链接的文字：交给视频下载
            let text = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?.absoluteString
                ?? pb.string(forType: .string)
            guard let t = text, LinkParser.firstURL(in: t) != nil else { return false }
            onDropLink?(t)
            return true
        }
        onDropFiles?(urls)
        return true
    }
}

// MARK: - 全屏翻译控制

@available(macOS 14.0, *)
final class ScreenTranslator: NSObject {
    private let orbPanel: NSPanel
    private let orb = OrbView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
    private var overlay: NSWindow?
    private let overlayView = OverlayView(frame: .zero)

    private(set) var isOn = false
    private var timer: Timer?
    private var busy = false
    private var generation = 0
    private var lastPrint: [UInt8] = []
    private var lastBlocks: [TextBlock] = []
    private let grabber = ScreenGrabber()
    /// 外部功能（输入框中译英、打开翻译框）
    var onTranslateField: (() -> Void)?
    var onOpenPanel: (() -> Void)?
    var onOpenShelf: (() -> Void)?
    var onOpenDownloader: ((String?) -> Void)?
    var onOpenClip: (() -> Void)?
    /// 开关状态变化（菜单栏按钮跟着变）
    var onStateChange: ((Bool) -> Void)?
    var orbFrame: NSRect { orbPanel.frame }
    func setBadge(_ n: Int) { orb.badge = n; toolbox.update(isOn: isOn, screenshots: n) }
    private lazy var toolbox: ToolboxController = {
        let t = ToolboxController()
        t.onTranslate = { [weak self] in self?.onOpenPanel?() }
        t.onShelf = { [weak self] in self?.onOpenShelf?() }
        t.onDownload = { [weak self] in self?.onOpenDownloader?(nil) }
        t.onClip = { [weak self] in self?.onOpenClip?() }
        t.onScreen = { [weak self] in self?.toggle() }
        t.onShoot = { ShelfShooter.shoot() }
        t.onField = { [weak self] in self?.onTranslateField?() }
        t.onAvatar = { [weak self] in self?.menuAvatar() }
        t.onMore = { [weak self] in self?.showOrbMenu(nil) }
        return t
    }()
    private var cache: [String: String] = [:]
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var failCount = 0

    var orbVisible: Bool { orbPanel.isVisible }

    override init() {
        orbPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        orbPanel.isOpaque = false
        orbPanel.backgroundColor = .clear
        orbPanel.hasShadow = true
        orbPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        orbPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        orbPanel.isMovableByWindowBackground = false
        orbPanel.becomesKeyOnlyIfNeeded = true
        orbPanel.hidesOnDeactivate = false
        orbPanel.contentView = orb
        orb.toolTip = "点一下选功能：整屏翻译 / 输入框中文变英文 / 翻译框 / 视频下载 / 截图中转站。拖动可移动；图片拖上来存进中转站，视频链接拖上来直接下载。"
        orb.onClick = { [weak self] in self?.toggleTools() }
        orb.onMoved = { [weak self] in self?.saveOrbPosition() }
        orb.onMenu = { [weak self] e in self?.showOrbMenu(e) }
        orb.registerForDraggedTypes([.fileURL, .URL, .string])
        orb.onDropLink = { [weak self] link in self?.onOpenDownloader?(link) }
        orb.onDropFiles = { urls in
            for u in urls { ShelfStore.shared.add(copyOf: u) }
            Toast.show("已存进截图中转站")
        }
        restoreOrbPosition()
        applyAvatar()
    }

    /// 有自定义形象就换上（形象画得大一点）
    func applyAvatar() {
        let img = Avatar.current
        orb.avatar = img
        let size = img == nil ? NSSize(width: 120, height: 58) : NSSize(width: 84, height: 84)
        var f = orbPanel.frame
        let center = NSPoint(x: f.midX, y: f.midY)
        f.size = size
        f.origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if let vf = orbPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            f.origin.x = min(max(f.origin.x, vf.minX + 5), vf.maxX - size.width - 5)
            f.origin.y = min(max(f.origin.y, vf.minY + 5), vf.maxY - size.height - 5)
        }
        orbPanel.setFrame(f, display: true)
        orb.frame = NSRect(origin: .zero, size: size)
        orbPanel.hasShadow = img == nil
    }

    // 小圆球位置
    private func restoreOrbPosition() {
        let d = UserDefaults.standard
        if d.object(forKey: "orbX") != nil {
            let p = NSPoint(x: d.double(forKey: "orbX"), y: d.double(forKey: "orbY"))
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -10, dy: -10).contains(p) }) {
                orbPanel.setFrameOrigin(p); return
            }
        }
        if let vf = NSScreen.main?.visibleFrame {
            orbPanel.setFrameOrigin(NSPoint(x: vf.maxX - 90, y: vf.midY))
        }
    }

    private func saveOrbPosition() {
        let o = orbPanel.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: "orbX")
        UserDefaults.standard.set(Double(o.y), forKey: "orbY")
        if isOn { contentMoved(hide: false, delay: 0.2) }
    }

    func showOrb() { orbPanel.orderFrontRegardless() }
    func hideOrb() { orbPanel.orderOut(nil); toolbox.panel.orderOut(nil) }
    func toggleTools() { toolbox.update(isOn: isOn, screenshots: orb.badge); toolbox.toggle(near: orbFrame) }

    private func showOrbMenu(_ e: NSEvent?) {
        let m = NSMenu()
        func item(_ title: String, _ sel: Selector, _ key: String = "") {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            if !key.isEmpty { it.keyEquivalentModifierMask = .option }
            it.target = self
            m.addItem(it)
        }
        item(isOn ? "恢复原文" : "整屏翻译成中文", #selector(menuToggle), "t")
        item("输入框：中文 → 英文", #selector(menuField), "e")
        item("打开翻译框（中英互译）", #selector(menuPanel), "a")
        m.addItem(.separator())
        item("视频下载（无水印原画质）", #selector(menuDownload), "v")
        item("片段截取（原画质 / 去水印）", #selector(menuClip), "c")
        m.addItem(.separator())
        item("截图中转站（\(ShelfStore.shared.items.count) 张）", #selector(menuShelf), "z")
        item("截一张存进中转站", #selector(menuShoot), "x")
        m.addItem(.separator())
        item("换个形象（用自己的图片）…", #selector(menuAvatar))
        if Avatar.current != nil { item("恢复奶油金胶囊", #selector(menuAvatarReset)) }
        item("隐藏悬浮入口", #selector(menuHide))
        let q = NSMenuItem(title: "退出截图翻译视频下载", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        m.addItem(q)
        // 菜单弹在小球左边，不挡住小球
        m.popUp(positioning: nil, at: NSPoint(x: -8, y: orb.bounds.maxY), in: orb)
    }

    @objc private func menuField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.onTranslateField?() }
    }
    @objc private func menuPanel() { onOpenPanel?() }
    @objc private func menuShelf() { onOpenShelf?() }
    @objc private func menuDownload() { onOpenDownloader?(nil) }
    @objc private func menuClip() { onOpenClip?() }
    @objc private func menuAvatar() { Avatar.choose { [weak self] ok in if ok { self?.applyAvatar() } } }
    @objc private func menuAvatarReset() { Avatar.reset(); applyAvatar() }
    @objc private func menuShoot() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ShelfShooter.shoot() }
    }
    @objc private func menuToggle() { toggle() }
    @objc private func menuHide() {
        if isOn { stop() }
        hideOrb()
        UserDefaults.standard.set(true, forKey: "orbHidden")
    }

    // 开关
    func toggle() { isOn ? stop() : start() }

    private var currentScreen: NSScreen {
        orbPanel.isVisible ? (orbPanel.screen ?? NSScreen.main!) : (NSScreen.main ?? NSScreen.screens[0])
    }

    func start() {
        if !CGPreflightScreenCaptureAccess() {
            RunLog.write("整屏翻译：没有「录屏」权限")
            CGRequestScreenCaptureAccess()
            let a = NSAlert()
            a.messageText = "需要「屏幕录制」权限"
            a.informativeText = "整屏翻译要先看到屏幕上的字。\n\n请在「系统设置 → 隐私与安全性 → 录屏与系统录音」里打开「截图翻译视频下载」，然后从菜单栏「译」退出，再重新打开一次。\n\n如果开关本来就是开的却还是不行（重装后常见）：选中它点「−」删掉，再点「+」把「应用程序」里的这个软件加回来。\n\n截下来的画面只在你的电脑上识别，只有识别出的文字会发给翻译服务。"
            a.addButton(withTitle: "打开系统设置")
            a.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn,
               let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(u)
            }
            return
        }
        isOn = true
        orb.isOn = true
        toolbox.update(isOn: true, screenshots: orb.badge)
        onStateChange?(true)
        RunLog.write("整屏翻译：开")
        orb.failed = false
        failCount = 0
        lastPrint = []
        lastBlocks = []
        makeOverlay()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.cycle(force: false) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] _ in
            self?.contentMoved(hide: true, delay: 0.25)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            self?.contentMoved(hide: false, delay: 0.15)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            // 翻页、切换窗口类按键
            let navKeys: Set<UInt16> = [116, 121, 115, 119, 125, 126, 49, 48]
            if navKeys.contains(e.keyCode) || e.modifierFlags.contains(.command) {
                self?.contentMoved(hide: true, delay: 0.3)
            }
        }) { monitors.append(m) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appSwitched),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        cycle(force: true)
    }

    func stop() {
        isOn = false
        orb.isOn = false
        toolbox.update(isOn: false, screenshots: orb.badge)
        onStateChange?(false)
        orb.busy = false
        orb.failed = false
        generation += 1
        timer?.invalidate(); timer = nil
        pending?.cancel(); pending = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        overlayView.items = []
        overlay?.orderOut(nil)
        lastBlocks = []
        lastPrint = []
    }

    @objc private func appSwitched() { contentMoved(hide: true, delay: 0.3) }

    private func makeOverlay() {
        let scr = currentScreen
        if overlay == nil {
            let w = NSWindow(contentRect: scr.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.contentView = overlayView
            overlay = w
        }
        overlay?.setFrame(scr.frame, display: false)
        overlayView.items = []
        overlay?.alphaValue = 1
        overlay?.orderFrontRegardless()
        orbPanel.orderFrontRegardless()
    }

    /// 内容动了：可选立即隐藏旧译文，停一会儿再重新识别
    private func contentMoved(hide: Bool, delay: Double) {
        guard isOn else { return }
        generation += 1
        if hide { overlay?.alphaValue = 0 }
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.cycle(force: hide) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func cycle(force: Bool) {
        guard isOn else { return }
        if busy {
            if force {   // 正在处理时又动了，处理完再来一次
                pending?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.cycle(force: true) }
                pending = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
            }
            return
        }
        busy = true
        let scr = currentScreen
        if overlay?.frame != scr.frame { overlay?.setFrame(scr.frame, display: false) }
        let scale = scr.backingScaleFactor
        let displayID = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let gen = generation
        let prevPrint = lastPrint
        let prevBlocks = lastBlocks
        let overlayShown = (overlay?.alphaValue ?? 0) > 0.5
        let cacheSnapshot = cache
        let grabber = self.grabber

        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            // 正在输入密码（系统安全输入）时完全暂停
            if IsSecureEventInputEnabled() {
                await MainActor.run {
                    self.busy = false
                    self.overlay?.alphaValue = 0
                    self.lastPrint = []
                    self.lastBlocks = []
                }
                return
            }
            do {
                let wins = Privacy.windows()
                let nPriv = wins.filter { $0.isPrivate }.count
                let (cg, dframe) = try await grabber.capture(displayID: displayID, scale: scale, wins: wins)
                let tCap = Date().timeIntervalSince(t0)
                guard let px = PixelSampler(cg) else { throw TError(message: "读不到画面") }
                let fp = px.fingerprint()
                let rows = px.changedRows(fp, prevPrint)
                if rows == nil && overlayShown && !force {
                    await MainActor.run { self.busy = false }
                    return
                }
                // 只重新识别变化的那几行（整屏宽），并把和它相交的旧文字块一起重认
                let W = CGFloat(cg.width), H = CGFloat(cg.height)
                var roi = CGRect.zero
                var keep = prevBlocks
                if let rr = rows {
                    let (y0, y1) = rr
                    var r = CGRect(x: 0, y: y0 - 40, width: W, height: (y1 - y0) + 80)
                    for b in prevBlocks where b.rect.intersects(r) { r = r.union(b.rect.insetBy(dx: 0, dy: -8)) }
                    let lo = max(0, r.minY), hi = min(H, r.maxY)
                    roi = CGRect(x: 0, y: lo, width: W, height: max(0, hi - lo))
                    keep = prevBlocks.filter { !$0.rect.intersects(roi) }
                }
                let t1 = Date()
                var fresh: [TextBlock] = []
                if roi.height > 4 {
                    let lines = await BlockOCR.lines(in: cg, roi: roi)
                    fresh = BlockOCR.group(lines)
                }
                let tOCR = Date().timeIntervalSince(t1)

                // 私密窗口里的字一律丢掉（这些窗口本来就没截进来，这里再保险一次）
                func gpt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                    CGPoint(x: dframe.minX + x / scale, y: dframe.minY + dframe.height - y / scale)
                }
                let blocks = (keep + fresh).filter { b in
                    let r = b.rect
                    let pts = [gpt(r.midX, r.midY), gpt(r.minX + 1, r.minY + 1), gpt(r.maxX - 1, r.minY + 1),
                               gpt(r.minX + 1, r.maxY - 1), gpt(r.maxX - 1, r.maxY - 1)]
                    return !pts.contains { Privacy.isPrivate(at: $0, wins) }
                }
                let targets = blocks.filter { BlockOCR.needsTranslation($0.text) }

                func makeItems(_ dict: [String: String]) -> [OverlayItem] {
                    var out: [OverlayItem] = []
                    for b in targets {
                        guard let zh = dict[b.text], zh != b.text else { continue }
                        let (bg, fg) = px.colors(around: b.rect)
                        let r = CGRect(x: b.rect.minX / scale, y: b.rect.minY / scale,
                                       width: b.rect.width / scale, height: b.rect.height / scale)
                        out.append(OverlayItem(rect: r, text: zh, bg: bg, fg: fg, lines: b.lines))
                    }
                    return out
                }

                let missing = Array(Set(targets.map { $0.text }.filter { cacheSnapshot[$0] == nil }))
                if !missing.isEmpty {
                    // 先把已经翻过的显示出来，新的翻完再补上
                    let quick = makeItems(cacheSnapshot)
                    await MainActor.run {
                        self.orb.busy = true
                        if gen == self.generation && self.isOn {
                            self.overlayView.items = quick
                            self.overlay?.alphaValue = 1
                        }
                    }
                }
                let t2 = Date()
                var newCache: [String: String] = [:]
                if !missing.isEmpty {
                    let tr = try await Translator.shared.batchToChinese(missing)
                    for (k, v) in zip(missing, tr) { newCache[k] = v }
                }
                let tTr = Date().timeIntervalSince(t2)
                var merged = cacheSnapshot
                for (k, v) in newCache { merged[k] = v }
                let items = makeItems(merged)

                let total = Date().timeIntervalSince(t0)
                let share = H > 0 ? Int(roi.height / H * 100) : 0
                RunLog.write(String(format: "总 %4.0f ms | 截屏 %3.0f | 识别 %4.0f (区域 %3d%%) | 翻译 %4.0f | 文字块 %3d | 新翻 %3d | 私密窗口 %d",
                                    total * 1000, tCap * 1000, tOCR * 1000, share, tTr * 1000, targets.count, missing.count, nPriv))

                await MainActor.run {
                    self.busy = false
                    self.orb.busy = false
                    for (k, v) in newCache { self.cache[k] = v }
                    if self.cache.count > 5000 { self.cache.removeAll() }
                    guard self.isOn else { return }
                    self.failCount = 0
                    self.orb.failed = false
                    // 处理期间画面又动过，就丢掉这次结果，等下一轮
                    guard gen == self.generation else { self.lastPrint = []; self.lastBlocks = []; return }
                    self.lastPrint = fp
                    self.lastBlocks = blocks
                    self.overlayView.items = items
                    self.overlay?.alphaValue = 1
                }
            } catch {
                RunLog.write("出错：\(error.localizedDescription)")
                await MainActor.run {
                    self.busy = false
                    self.orb.busy = false
                    guard self.isOn else { return }
                    self.failCount += 1
                    self.orb.failed = self.failCount >= 2
                }
            }
        }
    }
}

// MARK: - 运行记录（只记耗时和数量，不记任何文字内容）

enum RunLog {
    private static let url: URL? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("桌面翻译器")
        return FileManager.default.fileExists(atPath: dir.path) ? dir.appendingPathComponent("运行记录.log") : nil
    }()
    private static let queue = DispatchQueue(label: "runlog")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }()

    static func write(_ line: String) {
        guard let url = url else { return }
        queue.async {
            let text = "\(fmt.string(from: Date()))  \(line)\n"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 300_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
            } else {
                try? text.data(using: .utf8)!.write(to: url)
            }
        }
    }
}
