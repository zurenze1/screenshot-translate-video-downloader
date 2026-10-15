// 截图中转站：截图自动收进小球，之后可以一张、几张或全部拖到任何地方
import Cocoa
import Vision
import ImageIO

// MARK: - 存储

final class ShelfStore {
    static let shared = ShelfStore()
    let dir: URL
    private(set) var items: [URL] = []      // 新的在前
    private var listeners: [() -> Void] = []
    static let maxItems = 200

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("桌面翻译器/截图中转站", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }

    func observe(_ f: @escaping () -> Void) { listeners.append(f) }

    private func created(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        let exts: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "gif", "webp"]
        items = files.filter { exts.contains($0.pathExtension.lowercased()) }.sorted { created($0) > created($1) }
        if items.count > ShelfStore.maxItems {
            for u in items[ShelfStore.maxItems...] { try? FileManager.default.removeItem(at: u) }
            items = Array(items.prefix(ShelfStore.maxItems))
        }
        DispatchQueue.main.async { self.listeners.forEach { $0() } }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f
    }()

    func uniqueURL(_ name: String) -> URL {
        var u = dir.appendingPathComponent(name)
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(base) \(i).\(ext)"); i += 1
        }
        return u
    }

    func newShotURL() -> URL { uniqueURL("截图 \(ShelfStore.fmt.string(from: Date())).png") }

    /// 复制一份进来（原文件不动）
    func add(copyOf src: URL) {
        guard src.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL else { return }
        let dst = uniqueURL(src.lastPathComponent)
        do { try FileManager.default.copyItem(at: src, to: dst) } catch { NSLog("shelf add: \(error)"); return }
        reload()
    }

    func remove(_ urls: [URL]) {
        for u in urls where u.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
            // 放进废纸篓，删错了还能找回来
            if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: u) }
        }
        ThumbCache.forget(urls)
        reload()
    }
}

// MARK: - 自动收集系统截图（⌘⇧3 / ⌘⇧4 / ⌘⇧5）

final class ScreenshotWatcher: NSObject {
    private let query = NSMetadataQuery()
    private var seen = Set<String>()
    private let startedAt = Date()

    func start() {
        let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() + "/Desktop")
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [URL(fileURLWithPath: loc, isDirectory: true)]
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .NSMetadataQueryDidUpdate, object: query)
        query.start()
    }

    @objc private func update(_ n: Notification) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !seen.contains(path) else { continue }
            seen.insert(path)
            let created = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? .distantPast
            // 只收软件启动之后的新截图
            if created > startedAt.addingTimeInterval(-2) {
                ShelfStore.shared.add(copyOf: URL(fileURLWithPath: path))
            }
        }
    }
}

// MARK: - 缩略图

enum ThumbCache {
    private static var cache: [URL: NSImage] = [:]

    static func image(_ u: URL) -> NSImage? {
        if let c = cache[u] { return c }
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[u] = img
        return img
    }

    static func forget(_ urls: [URL]) { for u in urls { cache[u] = nil } }
}

// MARK: - 识别图片里的字

enum ImageOCR {
    static func text(of cg: CGImage, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            let lines = (req.results ?? []).compactMap { o -> String? in
                guard let c = o.topCandidates(1).first, c.confidence >= 0.4 else { return nil }
                return c.string
            }
            let t = ScreenOCR.mergeLines(lines)
            DispatchQueue.main.async { completion(t.isEmpty ? nil : t) }
        }
    }

    static func text(of url: URL, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: String? = nil
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
                let lines = (req.results ?? []).compactMap { o -> String? in
                    guard let c = o.topCandidates(1).first, c.confidence >= 0.4 else { return nil }
                    return c.string
                }
                let t = ScreenOCR.mergeLines(lines)
                out = t.isEmpty ? nil : t
            }
            DispatchQueue.main.async { completion(out) }
        }
    }
}

// MARK: - 一张缩略图

final class ThumbCell: NSView {
    let url: URL
    var selected = false { didSet { needsDisplay = true } }
    weak var owner: ShelfController?
    private var downPoint: NSPoint?
    private var dragging = false
    /// 缩略图实际画出来的区域；只有点在图上才算点中，点在空白处交给框选
    private var imageRect = NSRect.zero

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        toolTip = url.deletingPathExtension().lastPathComponent + "\n双击用「预览」打开"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let r = imageRect == .zero ? bounds.insetBy(dx: 10, dy: 10) : imageRect.insetBy(dx: -2, dy: -2)
        return r.contains(p) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        let bg = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        ProductTheme.surface.setFill()
        bg.fill()
        if let img = ThumbCache.image(url) {
            let area = r.insetBy(dx: 5, dy: 5)
            let s = min(area.width / img.size.width, area.height / img.size.height)
            let w = img.size.width * s, h = img.size.height * s
            let ir = NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
            imageRect = ir
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: ir, xRadius: 4, yRadius: 4).addClip()
            img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if selected {
            ProductTheme.gold.setStroke()
            bg.lineWidth = 3
            bg.stroke()
            let c = NSRect(x: r.maxX - 24, y: r.minY + 6, width: 18, height: 18)
            ProductTheme.gold.setFill()
            NSBezierPath(ovalIn: c).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
            let s = "✓" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: c.midX - sz.width / 2, y: c.midY - sz.height / 2), withAttributes: attrs)
        } else {
            ProductTheme.line.setStroke()
            bg.lineWidth = 1
            bg.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragging = false
        if event.clickCount == 2 { NSWorkspace.shared.open(url); return }
        window?.makeFirstResponder(superview)
        owner?.clicked(self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downPoint, !dragging else { return }
        let p = event.locationInWindow
        if hypot(p.x - d.x, p.y - d.y) < 4 { return }
        dragging = true
        owner?.beginDrag(from: self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { owner?.released(self, event: event) }
        downPoint = nil
    }
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

/// 中转站的格子区：在空白处按住左键拖出选框，框住的图都选上；Delete 删除，⌘A 全选，⌘C 复制
final class ShelfGrid: FlippedView {
    weak var owner: ShelfController?
    private var bandStart: NSPoint?
    private var baseSelection = Set<URL>()
    private let band = BandView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        band.isHidden = true
        addSubview(band)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        bandStart = convert(e.locationInWindow, from: nil)
        let f = e.modifierFlags
        baseSelection = (f.contains(.command) || f.contains(.shift)) ? (owner?.currentSelection ?? []) : []
        owner?.setSelection(baseSelection)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = bandStart else { return }
        autoscroll(with: e)
        let p = convert(e.locationInWindow, from: nil)
        let r = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        band.frame = r
        band.isHidden = false
        addSubview(band, positioned: .above, relativeTo: nil)
        owner?.bandSelect(r, base: baseSelection)
    }

    override func mouseUp(with e: NSEvent) {
        bandStart = nil
        band.isHidden = true
    }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch (e.keyCode, cmd) {
        case (51, _), (117, _): owner?.deleteSelectedFromKey()      // Delete / ⌦
        case (0, true): owner?.selectAllFromKey()                   // ⌘A
        case (8, true): owner?.copyFromKey()                        // ⌘C
        case (53, _): owner?.setSelection([])                       // Esc
        default: super.keyDown(with: e)
        }
    }
}

final class BandView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ProductTheme.gold.withAlphaComponent(0.15).setFill()
        bounds.fill()
        ProductTheme.gold.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
    }
}

// MARK: - 中转站窗口

final class ShelfController: NSObject, NSDraggingSource, NSWindowDelegate {
    let panel: NSPanel
    private let scroll = NSScrollView()
    private let grid = ShelfGrid()
    private let titleLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var cells: [ThumbCell] = []
    private var selection = Set<URL>()
    private var anchor: URL?
    var onTranslate: ((String?) -> Void)?
    var anchorFrame: (() -> NSRect?)?   // 小球的位置

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "截图中转站"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 480, height: 380)
        panel.delegate = self
        buildUI()
        ProductTheme.apply(to: panel)
        grid.owner = self
        ShelfStore.shared.observe { [weak self] in self?.reloadCells() }
        reloadCells()
    }

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func buildUI() {
        let content = panel.contentView!
        let header = ProductTheme.header("02 / 截图中转", "截完，下一秒就用上。", "在空白处框选，多张一起拖走。")
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let top = NSStackView(views: [titleLabel, spacer, button("全选", #selector(selectAll)), button("截一张 ⌥X", #selector(shoot))])
        top.orientation = .horizontal
        top.distribution = .fill

        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let bottom = NSStackView(views: [button("复制", #selector(copySelected)), button("翻译图上的字", #selector(translateSelected)),
                                         button("在访达中显示", #selector(reveal)), spacer2,
                                         button("删除", #selector(deleteSelected)), button("清空", #selector(clearAll))])
        bottom.orientation = .horizontal
        bottom.distribution = .fill

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = grid

        emptyLabel.stringValue = "还没有截图。\n\n用 ⌘⇧4 截图会自动收进来，或按 ⌥X 直接截一张。\n也可以把图片拖到小球上存进来。"
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        let hint = NSTextField(labelWithString: "在空白处按住拖出选框选多张；⌘ 点选；Delete 删除。选好后按住图片拖到想放的地方。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for v in [top, scroll, hint, bottom, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            top.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            bottom.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(layoutCells), name: NSView.frameDidChangeNotification, object: scroll)
        scroll.postsFrameChangedNotifications = true
    }

    // MARK: 显示

    func toggle() { panel.isVisible ? panel.close() : show() }

    func show() {
        if !panel.isVisible {
            if let f = anchorFrame?() ?? nil, let vf = NSScreen.screens.first(where: { $0.frame.intersects(f) })?.visibleFrame ?? NSScreen.main?.visibleFrame {
                let size = panel.frame.size
                var x = f.minX - size.width - 10
                if x < vf.minX { x = f.maxX + 10 }
                var y = f.midY - size.height / 2
                x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
                y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else { panel.center() }
        }
        reloadCells()
        panel.orderFrontRegardless()
    }

    private func reloadCells() {
        let items = ShelfStore.shared.items
        selection = selection.filter { items.contains($0) }
        cells.forEach { $0.removeFromSuperview() }
        cells = items.map { u in
            let c = ThumbCell(url: u)
            c.owner = self
            c.selected = selection.contains(u)
            grid.addSubview(c)
            return c
        }
        emptyLabel.isHidden = !items.isEmpty
        updateTitle()
        layoutCells()
    }

    @objc private func layoutCells() {
        let width = scroll.contentSize.width
        let gap: CGFloat = 10      // 格子之间留空，方便从空白处拖选框
        let cols = max(1, Int((width - gap) / 140))
        let cw = (width - gap * CGFloat(cols + 1)) / CGFloat(cols), ch = cw * 0.68
        for (i, c) in cells.enumerated() {
            c.frame = NSRect(x: gap + CGFloat(i % cols) * (cw + gap), y: gap + CGFloat(i / cols) * (ch + gap), width: cw, height: ch)
        }
        let rows = (cells.count + cols - 1) / cols
        grid.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, gap + CGFloat(rows) * (ch + gap) + 40))
    }

    private func updateTitle() {
        let n = ShelfStore.shared.items.count
        titleLabel.stringValue = selection.isEmpty ? "共 \(n) 张" : "共 \(n) 张 · 已选 \(selection.count) 张"
        for c in cells { c.selected = selection.contains(c.url) }
    }

    // MARK: 选择

    func clicked(_ cell: ThumbCell, event: NSEvent) {
        let f = event.modifierFlags
        if f.contains(.command) {
            if selection.contains(cell.url) { selection.remove(cell.url) } else { selection.insert(cell.url) }
            anchor = cell.url
        } else if f.contains(.shift), let a = anchor,
                  let i = cells.firstIndex(where: { $0.url == a }), let j = cells.firstIndex(where: { $0 === cell }) {
            for k in min(i, j)...max(i, j) { selection.insert(cells[k].url) }
        } else if !selection.contains(cell.url) {
            selection = [cell.url]
            anchor = cell.url
        }
        updateTitle()
    }

    /// 没拖动就松手：普通点击只留这一张
    func released(_ cell: ThumbCell, event: NSEvent) {
        let f = event.modifierFlags
        if !f.contains(.command) && !f.contains(.shift) && selection.count > 1 {
            selection = [cell.url]
            anchor = cell.url
            updateTitle()
        }
    }

    @objc private func selectAll() {
        let all = Set(ShelfStore.shared.items)
        selection = selection == all ? [] : all
        updateTitle()
    }

    private var selectedURLs: [URL] { ShelfStore.shared.items.filter { selection.contains($0) } }

    var currentSelection: Set<URL> { selection }
    func setSelection(_ s: Set<URL>) { selection = s; updateTitle() }

    /// 选框经过的图都选上（按着 ⌘/⇧ 时在原来的基础上增减）
    func bandSelect(_ r: NSRect, base: Set<URL>) {
        var s = base
        for c in cells where c.frame.insetBy(dx: 6, dy: 6).intersects(r) {
            if base.contains(c.url) { s.remove(c.url) } else { s.insert(c.url) }
        }
        if s != selection { selection = s; updateTitle() }
    }

    func deleteSelectedFromKey() { deleteSelected() }
    func selectAllFromKey() { selection = Set(ShelfStore.shared.items); updateTitle() }
    func copyFromKey() { copySelected() }

    // MARK: 拖出去

    func beginDrag(from cell: ThumbCell, event: NSEvent) {
        if !selection.contains(cell.url) { selection = [cell.url]; updateTitle() }
        let urls = selectedURLs
        var items: [NSDraggingItem] = []
        for (i, u) in urls.enumerated() {
            let di = NSDraggingItem(pasteboardWriter: u as NSURL)
            let r = cell.bounds.insetBy(dx: 8, dy: 8).offsetBy(dx: CGFloat(min(i, 4)) * 6, dy: CGFloat(min(i, 4)) * 6)
            di.setDraggingFrame(r, contents: ThumbCache.image(u))
            items.append(di)
        }
        let s = cell.beginDraggingSession(with: items, event: event, source: self)
        s.animatesToStartingPositionsOnCancelOrFail = true
        s.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    // MARK: 按钮

    @objc private func copySelected() {
        let urls = selectedURLs.isEmpty ? Array(ShelfStore.shared.items.prefix(1)) : selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if urls.count == 1, let data = try? Data(contentsOf: urls[0]) {
            // 一张图：同时放图片数据和文件，粘到聊天框、文档、访达都行
            let item = NSPasteboardItem()
            item.setData(data, forType: urls[0].pathExtension.lowercased() == "png" ? .png : .tiff)
            item.setString(urls[0].absoluteString, forType: .fileURL)
            pb.writeObjects([item])
        } else {
            pb.writeObjects(urls as [NSURL])
        }
        Toast.show("已复制 \(urls.count) 张，可以 ⌘V 粘贴")
    }

    @objc private func translateSelected() {
        guard let u = selectedURLs.first ?? ShelfStore.shared.items.first else { return }
        Toast.show("正在识别图上的字…")
        ImageOCR.text(of: u) { [weak self] t in self?.onTranslate?(t) }
    }

    @objc private func reveal() {
        let urls = selectedURLs.isEmpty ? [ShelfStore.shared.dir] : selectedURLs
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func deleteSelected() {
        guard !selection.isEmpty else { NSSound.beep(); return }
        let n = selection.count
        ShelfStore.shared.remove(selectedURLs)
        selection = []
        Toast.show("已删除 \(n) 张（在废纸篓里能找回）")
    }

    @objc private func clearAll() {
        let n = ShelfStore.shared.items.count
        guard n > 0 else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "清空中转站里的 \(n) 张截图？"
        a.informativeText = "只删除中转站里的副本（放进废纸篓），桌面上原来的截图不受影响。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            ShelfStore.shared.remove(ShelfStore.shared.items)
            selection = []
        }
    }

    @objc func shoot() { ShelfShooter.shoot() }
}

// MARK: - 直接截一张存进中转站（不经过桌面）

enum ShelfShooter {
    static func shoot() {
        let url = ShelfStore.shared.newShotURL()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", url.path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: url.path) {
                    ShelfStore.shared.reload()
                    Toast.show("已存进截图中转站")
                }
            }
        }
        try? p.run()
    }
}
