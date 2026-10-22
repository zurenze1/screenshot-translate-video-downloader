import Cocoa

@MainActor enum RelayImport {
    static func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Toast.show("正在保存 \(urls.count) 项副本，您可以继续用其他工具…")
        ShelfStore.shared.importFiles(urls) { added, skipped in
            if added == 0 { Toast.show("未存入：请拖入本地文件；文件夹、别名和本站文件不重复收取") }
            else { Toast.show("已存入 \(added) 项" + (skipped > 0 ? "，跳过 \(skipped) 项" : "，原文件保留")) }
        }
    }
}

enum ToolboxArtwork {
    static let image = NSImage(systemSymbolName: "leaf.circle", accessibilityDescription: "创作工具箱")
    static let forest = NSColor(srgbRed: 0.19, green: 0.32, blue: 0.28, alpha: 1)
    static let sage = NSColor(srgbRed: 0.86, green: 0.90, blue: 0.84, alpha: 1)
}

final class ToolboxHeroView: NSView {
    init() {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 152).isActive = true
        wantsLayer = true; layer?.backgroundColor = ProductTheme.surface.cgColor; layer?.cornerRadius = 18; layer?.masksToBounds = true
        let image = NSImageView(); image.image = ToolboxArtwork.image; image.imageScaling = .scaleProportionallyUpOrDown
        let eyebrow = ProductTheme.label("祖老大的工具箱 / DAILY TOOLS")
        let title = NSTextField(labelWithString: "让创作，顺手一点。")
        title.font = ProductTheme.serif(25); title.textColor = ProductTheme.ink
        let subtitle = NSTextField(labelWithString: "收好灵感，也照顾好手边的小事。")
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = ProductTheme.muted
        let text = NSStackView(views: [eyebrow, title, subtitle]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 11
        for v in [image, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: image.leadingAnchor, constant: -5),
            image.widthAnchor.constraint(equalToConstant: 116), image.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            image.topAnchor.constraint(equalTo: topAnchor, constant: 8), image.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 主入口也是投递区，直接拖入文件，无需先打开中转站。
final class RelayEntryButton: NSButton {
    private var receiving = false { didSet { needsDisplay = true } }
    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero); self.target = target; self.action = action
        title = "中转站"; isBordered = false; setButtonType(.momentaryPushIn)
        heightAnchor.constraint(equalToConstant: 88).isActive = true
        registerForDraggedTypes([.fileURL]); setAccessibilityLabel("中转站：截图、文件、视频。点击打开，或直接拖入文件")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !(sender.draggingSource is ShelfController) else { return [] }
        receiving = true; return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { receiving = false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { receiving = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        receiving = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        RelayImport.receive(urls); return true
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15)
        (receiving || isHighlighted ? ToolboxArtwork.forest.blended(withFraction: 0.18, of: .black)! : ToolboxArtwork.forest).setFill(); shape.fill()
        let circle = NSBezierPath(roundedRect: NSRect(x: 16, y: 23, width: 42, height: 42), xRadius: 12, yRadius: 12)
        NSColor.white.withAlphaComponent(0.12).setFill(); circle.fill()
        let icon = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 23, weight: .regular).applying(.init(paletteColors: [NSColor.white])))
        icon?.draw(in: NSRect(x: 26, y: 33, width: 22, height: 22))
        ((receiving ? "松手，放进中转站" : "中转站") as NSString).draw(at: NSPoint(x: 72, y: 48), withAttributes: [.font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor.white])
        ("截图 · 文件 · 视频    拖进来，一起带走" as NSString).draw(at: NSPoint(x: 72, y: 27), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
        ("⌥ Z  ↗" as NSString).draw(at: NSPoint(x: bounds.width - 67, y: 51), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
    }
}

final class RelayEmptyView: NSView {
    var filtered = false { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let imageRect = NSRect(x: bounds.midX - 48, y: 80, width: 96, height: 122)
        ToolboxArtwork.image?.draw(in: imageRect)
        let title = filtered ? "这里还没有匹配的文件" : "把手边的素材，先放在这里。"
        let subtitle = filtered ? "换个分类，或试试其他关键词。" : "拖入文件 / 视频，或点击「添加文件」；截图仍会自动收进来。"
        for (text, y, font, color) in [(title, CGFloat(51), ProductTheme.serif(20), ProductTheme.ink), (subtitle, CGFloat(24), NSFont.systemFont(ofSize: 11), ProductTheme.muted)] {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y), withAttributes: attrs)
        }
    }
}
