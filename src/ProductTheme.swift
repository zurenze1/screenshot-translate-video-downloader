import Cocoa
import AVKit

/// 与产品网页共用奶油白、香槟金和深橄榄灰，保持原生控件的键盘及辅助功能行为。
enum ProductTheme {
    static let paper = NSColor(srgbRed: 0.953, green: 0.937, blue: 0.906, alpha: 1)
    static let surface = NSColor(srgbRed: 0.990, green: 0.980, blue: 0.957, alpha: 1)
    static let soft = NSColor(srgbRed: 0.924, green: 0.902, blue: 0.857, alpha: 1)
    static let ink = NSColor(srgbRed: 0.184, green: 0.188, blue: 0.169, alpha: 1)
    static let muted = NSColor(srgbRed: 0.47, green: 0.46, blue: 0.41, alpha: 1)
    static let gold = NSColor(srgbRed: 0.245, green: 0.398, blue: 0.333, alpha: 1)
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
        if view is AVPlayerView || view is ProductHeaderView || view is ToolCardButton || view is ToolboxHeroView || view is RelayEntryButton { return }
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
        heightAnchor.constraint(equalToConstant: 88).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        wantsLayer = true; layer?.backgroundColor = ProductTheme.surface.cgColor; layer?.cornerRadius = 14; layer?.masksToBounds = true
        let artwork = NSImageView(); artwork.image = ToolboxArtwork.image; artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.translatesAutoresizingMaskIntoConstraints = false; addSubview(artwork)
        NSLayoutConstraint.activate([artwork.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), artwork.topAnchor.constraint(equalTo: topAnchor, constant: 5), artwork.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5), artwork.widthAnchor.constraint(equalToConstant: 62)])
        let e = ProductTheme.label(eyebrow)
        let t = NSTextField(labelWithString: title)
        t.font = ProductTheme.serif(22); t.textColor = ProductTheme.ink
        let s = NSTextField(labelWithString: subtitle)
        s.font = .systemFont(ofSize: 10); s.textColor = ProductTheme.muted
        s.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [e, t, s])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), stack.trailingAnchor.constraint(lessThanOrEqualTo: artwork.leadingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
            icon.draw(in: NSRect(x: 15, y: bounds.height - 31, width: 19, height: 19))
        }
        (shortcut as NSString).draw(at: NSPoint(x: bounds.width - 42, y: bounds.height - 25), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: ProductTheme.muted])
        (title as NSString).draw(at: NSPoint(x: 15, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: ProductTheme.ink])
        (detail as NSString).draw(at: NSPoint(x: 15, y: 10), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: ProductTheme.muted])
        if window?.firstResponder === self { ProductTheme.gold.setStroke(); let focus = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3), xRadius: 9, yRadius: 9); focus.lineWidth = 1.5; focus.stroke() }
    }
}

/// 工具窗口的唤起独立于应用激活；激活完成后只聚焦本次请求的窗口。
@MainActor final class ToolWindowPresenter: NSObject {
    static let shared = ToolWindowPresenter()
    private weak var pendingWindow: NSWindow?
    private weak var pendingFocus: NSResponder?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }

    nonisolated static func show(_ window: NSWindow, focus: NSResponder? = nil) {
        DispatchQueue.main.async { shared.present(window, focus: focus) }
    }

    private func present(_ window: NSWindow, focus: NSResponder?) {
        pendingWindow = window
        pendingFocus = focus
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        let target = window.attachedSheet ?? window
        target.makeKeyAndOrderFront(nil)
        if target === window, let focus { window.makeFirstResponder(focus) }
        if NSApp.isActive { finishPresentation() }
        else {
            NSApp.activate(ignoringOtherApps: true)
            // 激活可能在当前鼠标事件处理之后完成；不以固定延时猜测。
            DispatchQueue.main.async { [weak self] in
                if NSApp.isActive { self?.finishPresentation() }
            }
        }
    }

    @objc private func didBecomeActive(_ notification: Notification) { finishPresentation() }
    private func finishPresentation() {
        guard NSApp.isActive, let window = pendingWindow else { return }
        let focus = pendingFocus
        pendingWindow = nil; pendingFocus = nil
        guard window.isVisible else { return } // 已主动关闭的窗口不重新弹出
        let target = window.attachedSheet ?? window
        target.makeKeyAndOrderFront(nil)
        if target === window, let focus { window.makeFirstResponder(focus) }
    }
}

private final class ToolboxPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}


private final class ToolboxDocument: NSView { override var isFlipped: Bool { true } }

@MainActor final class ToolboxController: NSObject {
    let panel: NSPanel
    var onTranslate: (() -> Void)?
    var onShelf: (() -> Void)?
    var onDownload: (() -> Void)?
    var onClip: (() -> Void)?
    var onShoot: (() -> Void)?
    var onField: (() -> Void)?
    var onAvatar: (() -> Void)?
    var onMore: (() -> Void)?
    private let count = ProductTheme.label("")
    private let custom = NSStackView()
    private var outsideMonitor: Any?
    override init() {
        panel = ToolboxPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 660), styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "工具箱"; panel.minSize = NSSize(width: 480, height: 640)
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false; panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = panel.contentView!
        let header = ToolboxHeroView()
        let relay = RelayEntryButton(target: self, action: #selector(shelf))
        func card(_ title: String, _ detail: String, _ symbol: String, _ shortcut: String, _ action: Selector) -> NSButton {
            let button = ToolCardButton(title, detail: detail, symbol: symbol, shortcut: shortcut, target: self, action: action)
            button.heightAnchor.constraint(equalToConstant: 80).isActive = true; return button
        }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views); row.distribution = .fillEqually; row.spacing = 10; return row
        }
        let first = row([card("翻译框", "文字、截图，中英互译", "character.bubble", "⌥ A", #selector(translate)), card("视频下载", "链接下载，选择位置", "arrow.down.to.line", "⌥ V", #selector(download))])
        let second = row([card("片段截取", "只留需要的几秒", "scissors", "⌥ C", #selector(clip)), card("自媒体工作台", "选题、素材与创作资料", "rectangle.grid.2x2", "打开", #selector(openWorkbench))])
        custom.orientation = .vertical; custom.spacing = 10
        let tools = NSStackView(views: [first, second, custom])
        tools.orientation = .vertical; tools.alignment = .leading; tools.spacing = 10
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let document = ToolboxDocument(); scroll.documentView = document
        tools.translatesAutoresizingMaskIntoConstraints = false; document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(tools)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            tools.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2), tools.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -2),
            tools.topAnchor.constraint(equalTo: document.topAnchor, constant: 2), tools.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2),
        ])
        for view in [first, second, custom] as [NSView] { view.widthAnchor.constraint(equalTo: tools.widthAnchor).isActive = true }
        func button(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button }
        let quick = row([button("截一张  ⌥X", #selector(shoot)), button("输入框转英文  ⌥E", #selector(field))])
        quick.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let footer = row([button("换个形象", #selector(avatar)), button("添加工具…", #selector(addTool)), button("更多…", #selector(more))])
        footer.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let stack = NSStackView(views: [header, relay, scroll, quick, count, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        for view in [header, relay, scroll, quick, footer] as [NSView] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        ProductTheme.apply(to: panel)
        ToolboxLinks.shared.onChange = { [weak self] in self?.refreshCustom() }
        refreshCustom()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.panel.orderOut(nil) }
    }
    deinit { if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) } }
    private func refreshCustom() {
        custom.arrangedSubviews.forEach { custom.removeArrangedSubview($0); $0.removeFromSuperview() }
        custom.isHidden = ToolboxLinks.shared.items.isEmpty
        for item in ToolboxLinks.shared.items {
            let button = ToolCardButton(item.title, detail: item.kind == .application ? "我的应用" : "常用网页", symbol: item.kind == .application ? "app" : "link", shortcut: "打开", target: self, action: #selector(openCustom(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            button.heightAnchor.constraint(equalToConstant: 80).isActive = true
            let menu = NSMenu(); let remove = NSMenuItem(title: "从工具箱移除", action: #selector(ToolboxLinks.removeFromMenu(_:)), keyEquivalent: "")
            remove.target = ToolboxLinks.shared; remove.representedObject = item.id; menu.addItem(remove); button.menu = menu
            custom.addArrangedSubview(button); button.widthAnchor.constraint(equalTo: custom.widthAnchor).isActive = true
        }
    }
    func update(screenshots: Int) {
        count.stringValue = screenshots == 0 ? "中转站已准备好，拖入文件就能开始。" : "中转站 · \(screenshots) 项素材，随时可取。"
    }
    func toggle(near anchor: NSRect) {
        if panel.isVisible && panel.isKeyWindow { panel.orderOut(nil); return }
        let visible = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        let size = panel.frame.size
        var x = anchor.minX - size.width - 14
        if x < visible.minX + 10 { x = anchor.maxX + 14 }
        let y = min(max(anchor.midY - size.height / 2, visible.minY + 10), visible.maxY - size.height - 10)
        x = min(max(x, visible.minX + 10), visible.maxX - size.width - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y)); panel.makeKeyAndOrderFront(nil)
    }
    private func dismiss(_ callback: (() -> Void)?) { panel.orderOut(nil); callback?() }
    @objc private func translate() { dismiss(onTranslate) }
    @objc private func shelf() { dismiss(onShelf) }
    @objc private func download() { dismiss(onDownload) }
    @objc private func clip() { dismiss(onClip) }
    @objc private func openWorkbench() { panel.orderOut(nil); CompanionTool.workbench.open() }
    @objc private func addTool() { panel.orderOut(nil); ToolboxLinks.shared.promptToAdd() }
    @objc private func openCustom(_ sender: NSButton) {
        guard let item = ToolboxLinks.shared.items.first(where: { $0.id.uuidString == sender.identifier?.rawValue }) else { return }
        panel.orderOut(nil); ToolboxLinks.shared.open(item)
    }
    @objc private func shoot() { panel.orderOut(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.onShoot?() } }
    @objc private func field() { panel.orderOut(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.onField?() } }
    @objc private func avatar() { dismiss(onAvatar) }
    @objc private func more() { dismiss(onMore) }
}
