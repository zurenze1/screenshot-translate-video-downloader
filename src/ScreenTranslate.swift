import Cocoa
import Carbon

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
        let title = "工具箱"
        (title as NSString).draw(at: NSPoint(x: 51, y: bounds.midY + 1), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: ProductTheme.ink])
        ((busy ? "正在翻译…" : "翻译 · 创作") as NSString).draw(at: NSPoint(x: 51, y: bounds.midY - 13), withAttributes: [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: ProductTheme.muted])
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

    // 把图片拖到小球上，存进中转站
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


@MainActor final class ToolboxHubController: NSObject {
    private let orbPanel: NSPanel
    private let orb = OrbView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
    var onTranslateField: (() -> Void)?
    var onOpenPanel: (() -> Void)?
    var onOpenShelf: (() -> Void)?
    var onOpenDownloader: ((String?) -> Void)?
    var onOpenClip: (() -> Void)?
    var orbFrame: NSRect { orbPanel.frame }
    var orbVisible: Bool { orbPanel.isVisible }
    private lazy var toolbox: ToolboxController = {
        let t = ToolboxController()
        t.onTranslate = { [weak self] in self?.onOpenPanel?() }
        t.onShelf = { [weak self] in self?.onOpenShelf?() }
        t.onDownload = { [weak self] in self?.onOpenDownloader?(nil) }
        t.onClip = { [weak self] in self?.onOpenClip?() }
        t.onShoot = { ShelfShooter.shoot() }
        t.onField = { [weak self] in self?.onTranslateField?() }
        t.onAvatar = { [weak self] in self?.menuAvatar() }
        t.onMore = { [weak self] in self?.showOrbMenu(nil) }
        return t
    }()
    override init() {
        orbPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        orbPanel.title = "工具箱 · 悬浮入口"
        orbPanel.isOpaque = false; orbPanel.backgroundColor = .clear; orbPanel.hasShadow = true
        orbPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        orbPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        orbPanel.isMovableByWindowBackground = false; orbPanel.becomesKeyOnlyIfNeeded = true
        orbPanel.hidesOnDeactivate = false; orbPanel.contentView = orb
        orb.toolTip = "工具箱：翻译、截图、视频和自媒体工作台。点开选择工具，拖动可移动。"
        orb.setAccessibilityElement(true); orb.setAccessibilityRole(.button); orb.setAccessibilityLabel("打开工具箱")
        orb.onClick = { [weak self] in self?.toggleTools() }
        orb.onMoved = { [weak self] in self?.saveOrbPosition() }
        orb.onMenu = { [weak self] event in self?.showOrbMenu(event) }
        orb.registerForDraggedTypes([.fileURL, .URL, .string])
        orb.onDropLink = { [weak self] text in self?.onOpenDownloader?(text) }
        orb.onDropFiles = { urls in RelayImport.receive(urls) }
        restoreOrbPosition(); applyAvatar()
    }
    func setBadge(_ count: Int) { orb.badge = count; toolbox.update(screenshots: count) }
    func showOrb() { orbPanel.orderFrontRegardless() }
    func hideOrb() { orbPanel.orderOut(nil); toolbox.panel.orderOut(nil) }
    func toggleTools() { toolbox.update(screenshots: orb.badge); toolbox.toggle(near: orbFrame) }
    func showTools() { showOrb(); if !toolbox.panel.isVisible { toggleTools() } }
    func applyAvatar() {
        let image = Avatar.current; orb.avatar = image
        let size = image == nil ? NSSize(width: 120, height: 58) : NSSize(width: 84, height: 84)
        var frame = orbPanel.frame; let center = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = size; frame.origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if let visible = orbPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX + 5), visible.maxX - size.width - 5)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 5), visible.maxY - size.height - 5)
        }
        orbPanel.setFrame(frame, display: true); orb.frame = NSRect(origin: .zero, size: size); orbPanel.hasShadow = image == nil
    }
    private func restoreOrbPosition() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "orbX") != nil {
            let point = NSPoint(x: defaults.double(forKey: "orbX"), y: defaults.double(forKey: "orbY"))
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -10, dy: -10).contains(point) }) { orbPanel.setFrameOrigin(point); return }
        }
        if let visible = NSScreen.main?.visibleFrame { orbPanel.setFrameOrigin(NSPoint(x: visible.maxX - 130, y: visible.midY)) }
    }
    private func saveOrbPosition() {
        UserDefaults.standard.set(Double(orbFrame.minX), forKey: "orbX"); UserDefaults.standard.set(Double(orbFrame.minY), forKey: "orbY")
    }
    private func showOrbMenu(_ event: NSEvent?) {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self
            if !key.isEmpty { entry.keyEquivalentModifierMask = .option }; menu.addItem(entry)
        }
        item("打开工具箱", #selector(menuTools))
        item("翻译框", #selector(menuPanel), "a")
        item("中转站（\(ShelfStore.shared.items.count) 张）", #selector(menuShelf), "z")
        item("截一张存进中转站", #selector(menuShoot), "x")
        item("录屏（区域 / 声音 / 预览）", #selector(menuRecord))
        item("输入框：中文 → 英文", #selector(menuField), "e")
        menu.addItem(.separator())
        item("视频素材采集", #selector(menuDownload), "v"); item("片段截取", #selector(menuClip), "c")
        item("自媒体工作台", #selector(menuWorkbench)); item("添加工具…", #selector(menuAddTool))
        menu.addItem(.separator())
        item("换个形象…", #selector(menuAvatar))
        if Avatar.current != nil { item("恢复默认工具箱", #selector(menuAvatarReset)) }
        item("隐藏悬浮入口", #selector(menuHide))
        let quit = NSMenuItem(title: "退出工具箱", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""); menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: -8, y: orb.bounds.maxY), in: orb)
    }
    @objc private func menuTools() { showTools() }
    @objc private func menuPanel() { onOpenPanel?() }
    @objc private func menuShelf() { onOpenShelf?() }
    @objc private func menuDownload() { onOpenDownloader?(nil) }
    @objc private func menuClip() { onOpenClip?() }
    @objc private func menuRecord() { RecordingEntry.show() }
    @objc private func menuWorkbench() { CompanionTool.workbench.open() }
    @objc private func menuAddTool() { ToolboxLinks.shared.promptToAdd() }
    @objc private func menuField() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.onTranslateField?() } }
    @objc private func menuShoot() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ShelfShooter.shoot() } }
    @objc private func menuAvatar() { Avatar.choose { [weak self] success in if success { self?.applyAvatar() } } }
    @objc private func menuAvatarReset() { Avatar.reset(); applyAvatar() }
    @objc private func menuHide() { hideOrb(); UserDefaults.standard.set(true, forKey: "orbHidden") }
}
