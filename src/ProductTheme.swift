import Cocoa
import AVKit

/// 与产品网页共用奶油白、香槟金和深橄榄灰，保持原生控件的键盘及辅助功能行为。
enum ProductTheme {
    static let paper = NSColor(srgbRed: 0.953, green: 0.937, blue: 0.906, alpha: 1)
    static let surface = NSColor(srgbRed: 0.990, green: 0.980, blue: 0.957, alpha: 1)
    static let soft = NSColor(srgbRed: 0.924, green: 0.902, blue: 0.857, alpha: 1)
    static let ink = NSColor(srgbRed: 0.184, green: 0.188, blue: 0.169, alpha: 1)
    static let muted = NSColor(srgbRed: 0.47, green: 0.46, blue: 0.41, alpha: 1)
    static let gold = NSColor(srgbRed: 0.592, green: 0.482, blue: 0.286, alpha: 1)
    static let line = NSColor(srgbRed: 0.78, green: 0.73, blue: 0.63, alpha: 0.45)
    static let dark = NSColor(srgbRed: 0.20, green: 0.22, blue: 0.185, alpha: 1)

    static func serif(_ size: CGFloat) -> NSFont {
        NSFont(name: "Songti SC", size: size) ?? .systemFont(ofSize: size, weight: .medium)
    }

    static func apply(to window: NSWindow) {
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = paper
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        if let root = window.contentView {
            root.wantsLayer = true
            root.layer?.backgroundColor = paper.cgColor
            style(root)
        }
    }

    private static func style(_ view: NSView) {
        if view is AVPlayerView || view is ProductHeaderView || view is ToolCardButton { return }
        if let scroll = view as? NSScrollView {
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 10
            scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = line.cgColor
            scroll.layer?.masksToBounds = true
            if scroll.drawsBackground { scroll.backgroundColor = surface }
        }
        if let text = view as? NSTextView {
            text.textColor = ink
            text.insertionPointColor = gold
            text.selectedTextAttributes = [.backgroundColor: gold.withAlphaComponent(0.20), .foregroundColor: ink]
            if text.drawsBackground { text.backgroundColor = surface }
        } else if let popup = view as? NSPopUpButton {
            popup.font = .systemFont(ofSize: 11)
            popup.contentTintColor = ink
        } else if let button = view as? NSButton {
            styleButton(button)
        } else if let field = view as? NSTextField {
            if field.isEditable {
                field.textColor = ink
                field.backgroundColor = surface
                field.focusRingType = .default
            } else if field.identifier?.rawValue != "preserveThemeColor" {
                field.textColor = (field.font?.pointSize ?? 12) <= 12 ? muted : ink
            }
        } else if let separator = view as? NSBox, separator.boxType == .separator {
            separator.borderColor = line
        }
        view.subviews.forEach { style($0) }
    }

    static func header(_ eyebrow: String, _ title: String, _ subtitle: String) -> NSView {
        ProductHeaderView(eyebrow: eyebrow, title: title, subtitle: subtitle)
    }

    static func primary(_ button: NSButton) { button.identifier = NSUserInterfaceItemIdentifier("primary") }

    static func styleButton(_ button: NSButton) {
        let isPrimary = button.identifier?.rawValue == "primary"
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.bezelColor = isPrimary ? dark : surface
        button.contentTintColor = isPrimary ? surface : ink
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: isPrimary ? surface : ink])
    }

    static func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 10, weight: .medium)
        f.textColor = gold
        f.identifier = NSUserInterfaceItemIdentifier("preserveThemeColor")
        return f
    }

    static func drawMark(in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.27, yRadius: rect.height * 0.27)
        NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.95, blue: 0.87, alpha: 1), ending: soft)?.draw(in: shape, angle: -55)
        line.setStroke(); shape.lineWidth = 0.8; shape.stroke()
        let r = rect.insetBy(dx: rect.width * 0.25, dy: rect.height * 0.25)
        let d = r.width * 0.25
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.minY + d)); p.line(to: NSPoint(x: r.minX, y: r.minY)); p.line(to: NSPoint(x: r.minX + d, y: r.minY))
        p.move(to: NSPoint(x: r.maxX - d, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.minY)); p.line(to: NSPoint(x: r.maxX, y: r.minY + d))
        p.move(to: NSPoint(x: r.maxX, y: r.maxY - d)); p.line(to: NSPoint(x: r.maxX, y: r.maxY)); p.line(to: NSPoint(x: r.maxX - d, y: r.maxY))
        p.move(to: NSPoint(x: r.minX + d, y: r.maxY)); p.line(to: NSPoint(x: r.minX, y: r.maxY)); p.line(to: NSPoint(x: r.minX, y: r.maxY - d))
        gold.setStroke(); p.lineWidth = max(1.3, rect.width * 0.035); p.lineCapStyle = .round; p.stroke()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: rect.midX - d * 0.35, y: rect.midY - d * 0.7))
        triangle.line(to: NSPoint(x: rect.midX + d * 0.8, y: rect.midY))
        triangle.line(to: NSPoint(x: rect.midX - d * 0.35, y: rect.midY + d * 0.7))
        triangle.close(); gold.setFill(); triangle.fill()
    }
}

final class ProductHeaderView: NSView {
    init(eyebrow: String, title: String, subtitle: String) {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 68).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        let e = ProductTheme.label(eyebrow)
        let t = NSTextField(labelWithString: title)
        t.font = ProductTheme.serif(24); t.textColor = ProductTheme.ink
        let s = NSTextField(labelWithString: subtitle)
        s.font = .systemFont(ofSize: 10); s.textColor = ProductTheme.muted
        s.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [e, t, s])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 可直接点的原生工具卡，不以不可访问的图片代替操作。
final class ToolCardButton: NSButton {
    let symbol: String
    let detail: String
    let shortcut: String
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(_ title: String, detail: String, symbol: String, shortcut: String, target: AnyObject?, action: Selector) {
        self.symbol = symbol; self.detail = detail; self.shortcut = shortcut
        super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        isBordered = false; setButtonType(.momentaryPushIn)
        setAccessibilityLabel(title + "，" + detail + "，" + shortcut)
        toolTip = title + " · " + shortcut
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 155, height: 94) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        (isHighlighted ? ProductTheme.soft : ProductTheme.surface).setFill(); shape.fill()
        (hovered || isHighlighted ? ProductTheme.gold.withAlphaComponent(0.7) : ProductTheme.line).setStroke()
        shape.lineWidth = 1; shape.stroke()
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 19, weight: .regular).applying(.init(paletteColors: [ProductTheme.gold]))) {
            icon.draw(in: NSRect(x: 15, y: bounds.height - 36, width: 21, height: 21))
        }
        (shortcut as NSString).draw(at: NSPoint(x: bounds.width - 42, y: bounds.height - 29), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: ProductTheme.muted])
        (title as NSString).draw(at: NSPoint(x: 15, y: 31), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: ProductTheme.ink])
        (detail as NSString).draw(at: NSPoint(x: 15, y: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: ProductTheme.muted])
        if window?.firstResponder === self { ProductTheme.gold.setStroke(); let focus = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3), xRadius: 9, yRadius: 9); focus.lineWidth = 1.5; focus.stroke() }
    }
}

private final class ToolboxPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class ToolboxController: NSObject {
    let panel: NSPanel
    var onTranslate: (() -> Void)?
    var onShelf: (() -> Void)?
    var onDownload: (() -> Void)?
    var onClip: (() -> Void)?
    var onScreen: (() -> Void)?
    var onShoot: (() -> Void)?
    var onField: (() -> Void)?
    var onAvatar: (() -> Void)?
    var onMore: (() -> Void)?
    private let screenButton = NSButton(title: "全屏中文   ⌥T", target: nil, action: nil)
    private let screenCaption = NSTextField(labelWithString: "点一下，把看到的外文盖成中文。")
    private let count = ProductTheme.label("翻译 · 截图 · 视频，随手一用。")
    private var outsideMonitor: Any?

    override init() {
        panel = ToolboxPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 514), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "截图翻译视频下载 · 工具面板"
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = panel.contentView!
        let header = ProductTheme.header("截图翻译视频下载", "灵感，接着发生。", "翻译 · 截图 · 下载，都在手边。")
        screenButton.bezelStyle = .rounded; ProductTheme.primary(screenButton)
        screenButton.target = self; screenButton.action = #selector(screen)
        screenButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        screenCaption.font = .systemFont(ofSize: 10)
        let cards = [
            ToolCardButton("翻译框", detail: "粘贴文字，拖入截图", symbol: "character.bubble", shortcut: "⌥ A", target: self, action: #selector(translate)),
            ToolCardButton("截图中转", detail: "框选几张，一起拖走", symbol: "rectangle.stack", shortcut: "⌥ Z", target: self, action: #selector(shelf)),
            ToolCardButton("视频下载", detail: "粘贴链接，选择位置", symbol: "arrow.down.to.line", shortcut: "⌥ V", target: self, action: #selector(download)),
            ToolCardButton("片段截取", detail: "好动效，只留那几秒", symbol: "scissors", shortcut: "⌥ C", target: self, action: #selector(clip)),
        ]
        cards.forEach { $0.heightAnchor.constraint(equalToConstant: 94).isActive = true }
        let first = NSStackView(views: Array(cards.prefix(2))), second = NSStackView(views: Array(cards.suffix(2)))
        for row in [first, second] { row.distribution = .fillEqually; row.spacing = 10; row.heightAnchor.constraint(equalToConstant: 94).isActive = true }
        func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b }
        let quick = NSStackView(views: [button("截一张  ⌥X", #selector(shoot)), button("输入框转英文  ⌥E", #selector(field))])
        quick.distribution = .fillEqually; quick.spacing = 10
        quick.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let footer = NSStackView(views: [button("换个形象", #selector(avatar)), button("产品介绍 ↗", #selector(website)), button("更多…", #selector(more))])
        footer.distribution = .fillEqually; footer.spacing = 8
        footer.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let breathing = NSView()
        breathing.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let stack = NSStackView(views: [header, screenButton, screenCaption, first, second, quick, count, breathing, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)])
        for v in [header, screenButton, first, second, quick, footer] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        ProductTheme.apply(to: panel)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.panel.orderOut(nil) }
    }
    deinit { if let m = outsideMonitor { NSEvent.removeMonitor(m) } }

    func update(isOn: Bool, screenshots: Int) {
        screenButton.title = isOn ? "恢复原文   ⌥T" : "全屏中文   ⌥T"
        ProductTheme.styleButton(screenButton)
        screenCaption.stringValue = isOn ? "整屏翻译已开启，再点一次恢复原文。" : "点一下，把看到的外文盖成中文。"
        count.stringValue = screenshots == 0 ? "翻译 · 截图 · 视频，随手一用。" : "截图中转站里有 \(screenshots) 张，随时可取。"
    }
    func toggle(near anchor: NSRect) {
        if panel.isVisible { panel.orderOut(nil); return }
        let vf = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        let size = panel.frame.size
        var x = anchor.minX - size.width - 14
        if x < vf.minX + 10 { x = anchor.maxX + 14 }
        let y = min(max(anchor.midY - size.height / 2, vf.minY + 10), vf.maxY - size.height - 10)
        x = min(max(x, vf.minX + 10), vf.maxX - size.width - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y)); panel.makeKeyAndOrderFront(nil)
    }
    private func dismiss(_ f: (() -> Void)?) { panel.orderOut(nil); f?() }
    @objc private func translate() { dismiss(onTranslate) }
    @objc private func shelf() { dismiss(onShelf) }
    @objc private func download() { dismiss(onDownload) }
    @objc private func clip() { dismiss(onClip) }
    @objc private func screen() { dismiss(onScreen) }
    @objc private func shoot() { panel.orderOut(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.onShoot?() } }
    @objc private func field() { panel.orderOut(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.onField?() } }
    @objc private func avatar() { dismiss(onAvatar) }
    @objc private func more() { dismiss(onMore) }
    @objc private func website() { panel.orderOut(nil); NSWorkspace.shared.open(URL(string: "https://zurenze1.github.io/screenshot-translate-video-downloader/")!) }
}
