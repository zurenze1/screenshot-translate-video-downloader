// 统一中转站：自动收集截图，保存文件与视频副本，批量取用。
import Cocoa
import Vision
import ImageIO
import QuickLookThumbnailing

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
                ShelfStore.shared.importFiles([URL(fileURLWithPath: path)]) { _, _ in }
            }
        }
    }
}

// MARK: - 缩略图

enum ThumbCache {
    private static var cache: [URL: NSImage] = [:]
    private static var requested = Set<URL>()

    static func image(_ u: URL) -> NSImage? {
        if let c = cache[u] { return c }
        if RelayKind.of(u) != .image {
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            cache[u] = icon
            if requested.insert(u).inserted {
                let request = QLThumbnailGenerator.Request(fileAt: u, size: NSSize(width: 320, height: 220), scale: 2, representationTypes: .thumbnail)
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    guard let rep else { return }
                    DispatchQueue.main.async {
                        cache[u] = rep.nsImage
                        NotificationCenter.default.post(name: .init("relayThumbnailReady"), object: nil)
                    }
                }
            }
            return icon
        }
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return NSWorkspace.shared.icon(forFile: u.path) }
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
        toolTip = url.lastPathComponent + "\n双击用默认应用打开 · 可拖到其他软件"
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(url.lastPathComponent + "，" + RelayKind.of(url).title)
        setAccessibilityHelp("单击选择，双击打开；按住拖出")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let r = bounds.insetBy(dx: 3, dy: 3)
        return r.contains(p) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        let bg = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        ProductTheme.surface.setFill()
        bg.fill()
        if let img = ThumbCache.image(url) {
            let area = NSRect(x: r.minX + 8, y: r.minY + 8, width: r.width - 16, height: r.height - 49)
            let s = min(area.width / img.size.width, area.height / img.size.height)
            let w = img.size.width * s, h = img.size.height * s
            let ir = NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
            imageRect = ir
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: ir, xRadius: 4, yRadius: 4).addClip()
            img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let name = NSRect(x: r.minX + 10, y: r.maxY - 36, width: r.width - 20, height: 17)
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
        (url.lastPathComponent as NSString).draw(in: name, withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: ProductTheme.ink, .paragraphStyle: style])
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let info = RelayKind.of(url).title + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        (info as NSString).draw(in: NSRect(x: r.minX + 10, y: r.maxY - 19, width: r.width - 20, height: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: ProductTheme.muted])
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
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource is ShelfController ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        RelayImport.receive(urls); return true
    }
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

final class ShelfController: NSObject, NSDraggingSource, NSWindowDelegate, NSSearchFieldDelegate {
    let panel: NSPanel
    private let scroll = NSScrollView()
    private let grid = ShelfGrid()
    private let titleLabel = NSTextField(labelWithString: "")
    private let emptyLabel = RelayEmptyView(frame: .zero)
    private let filters = NSSegmentedControl(labels: ["全部", "图片", "视频", "文件"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private var filter: RelayKind { RelayKind(rawValue: filters.selectedSegment) ?? .all }
    private var visibleItems: [URL] {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShelfStore.shared.items.filter { (filter == .all || RelayKind.of($0) == filter) && (query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query)) }
    }
    private var cells: [ThumbCell] = []
    private var selection = Set<URL>()
    private var anchor: URL?
    var onTranslate: ((String?) -> Void)?
    var anchorFrame: (() -> NSRect?)?   // 小球的位置

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "中转站"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 660, height: 500)
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
        let header = ProductTheme.header("RELAY / 素材中转站", "先放这里，等会儿接着用。", "截图自动收集 · 文件与视频拖入 · 保存副本，原件不动")
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let top = NSStackView(views: [titleLabel, spacer, button("添加文件…", #selector(addFiles)), button("全选", #selector(selectAll)), button("录屏", #selector(record)), button("截一张 ⌥X", #selector(shoot))])
        filters.selectedSegment = 0; filters.selectedSegmentBezelColor = ToolboxArtwork.forest; filters.target = self; filters.action = #selector(filterChanged)
        search.placeholderString = "搜索文件名"; search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let searchSpacer = NSView(); searchSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let filterBar = NSStackView(views: [filters, searchSpacer, search]); filterBar.spacing = 12
        top.orientation = .horizontal
        top.distribution = .fill

        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let bottom = NSStackView(views: [button("复制", #selector(copySelected)), button("翻译图上的字", #selector(translateSelected)),
                                         button("在访达中显示", #selector(reveal)), button("存入 Eagle…", #selector(exportEagle)), spacer2,
                                         button("删除", #selector(deleteSelected)), button("清空", #selector(clearAll))])
        bottom.orientation = .horizontal
        bottom.distribution = .fill

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = grid


        let hint = NSTextField(labelWithString: "拖入文件保存副本 · 框选或 ⌘ 点选后一起拖出 · 双击打开 · Delete 移到废纸篓")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for v in [top, filterBar, scroll, hint, bottom, emptyLabel] as [NSView] {
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
            filterBar.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            filterBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            filterBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 12),
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
            emptyLabel.heightAnchor.constraint(equalToConstant: 220),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(layoutCells), name: NSView.frameDidChangeNotification, object: scroll)
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: .init("relayThumbnailReady"), object: nil, queue: .main) { [weak self] _ in self?.cells.forEach { $0.needsDisplay = true } }
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
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(grid)
    }

    private func reloadCells() {
        let items = visibleItems
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
        emptyLabel.filtered = !ShelfStore.shared.items.isEmpty
        updateTitle()
        layoutCells()
    }

    @objc private func layoutCells() {
        let width = scroll.contentSize.width
        let gap: CGFloat = 10      // 格子之间留空，方便从空白处拖选框
        let cols = max(1, Int((width - gap) / 140))
        let cw = (width - gap * CGFloat(cols + 1)) / CGFloat(cols), ch = cw * 0.68 + 43
        for (i, c) in cells.enumerated() {
            c.frame = NSRect(x: gap + CGFloat(i % cols) * (cw + gap), y: gap + CGFloat(i / cols) * (ch + gap), width: cw, height: ch)
        }
        let rows = (cells.count + cols - 1) / cols
        grid.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, gap + CGFloat(rows) * (ch + gap) + 40))
    }

    private func updateTitle() {
        let n = ShelfStore.shared.items.count
        let busy = ShelfStore.shared.isImporting ? " · 正在存入…" : ""
        titleLabel.stringValue = "共 \(n) 项 · 当前 \(visibleItems.count) 项" + (selection.isEmpty ? "" : " · 已选 \(selection.count) 项") + busy
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
        let all = Set(visibleItems)
        selection = selection == all ? [] : all
        updateTitle()
    }

    private var selectedURLs: [URL] { visibleItems.filter { selection.contains($0) } }
    @MainActor @objc private func record() { panel.orderOut(nil); RecordingEntry.show() }
    @MainActor @objc private func exportEagle() {
        guard !selectedURLs.isEmpty else { Toast.show("请先选中要存入 Eagle 的素材。"); return }
        panel.orderOut(nil); EagleExportController.shared.show(urls: selectedURLs)
    }

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
    func selectAllFromKey() { selection = Set(visibleItems); updateTitle() }
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
        let urls = selectedURLs.isEmpty ? Array(visibleItems.prefix(1)) : selectedURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if urls.count == 1, RelayKind.of(urls[0]) == .image, let image = NSImage(contentsOf: urls[0]), let data = image.tiffRepresentation {
            // 一张图：同时放图片数据和文件，粘到聊天框、文档、访达都行
            let item = NSPasteboardItem()
            item.setData(data, forType: .tiff)
            item.setString(urls[0].absoluteString, forType: .fileURL)
            pb.writeObjects([item])
        } else {
            pb.writeObjects(urls as [NSURL])
        }
        Toast.show("已复制 \(urls.count) 项，可以 ⌘V 粘贴")
    }

    @objc private func translateSelected() {
        guard let u = selectedURLs.first ?? visibleItems.first, RelayKind.of(u) == .image else { Toast.show("请选择一张图片再识别文字"); return }
        Toast.show("正在识别图上的字…")
        ImageOCR.text(of: u) { [weak self] t in self?.onTranslate?(t) }
    }

    @objc private func reveal() {
        let urls = selectedURLs.isEmpty ? [ShelfStore.shared.dir] : selectedURLs
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func deleteSelected() {
        guard !selection.isEmpty else { NSSound.beep(); return }
        let expected = selection.count
        let n = ShelfStore.shared.remove(selectedURLs)
        ThumbCache.forget(selectedURLs); selection = []
        Toast.show(n == expected ? "已移除 \(n) 项，可从废纸篓恢复" : "已移除 \(n) 项，部分文件未能移除，已保留")
    }

    @objc private func clearAll() {
        let n = ShelfStore.shared.items.count
        guard n > 0 else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "清空中转站里的 \(n) 项？"
        a.informativeText = "将全部分类中的副本移到废纸篓。原文件不受影响。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            let removed = ShelfStore.shared.remove(ShelfStore.shared.items)
            selection = []
            Toast.show("已移除 \(removed) 项；未能移除的文件继续保留")
        }
    }

    @objc private func filterChanged() { selection = []; reloadCells() }
    func controlTextDidChange(_ obj: Notification) { selection = []; reloadCells() }
    @objc private func addFiles() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let picker = NSOpenPanel(); picker.title = "存入中转站"; picker.prompt = "保存副本"
        picker.allowsMultipleSelection = true; picker.canChooseDirectories = false; picker.canChooseFiles = true
        picker.beginSheetModal(for: panel) { response in if response == .OK { DispatchQueue.main.async { RelayImport.receive(picker.urls) } } }
    }
    @objc func shoot() { panel.orderOut(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ShelfShooter.shoot() } }
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
                    Toast.show("已存进中转站")
                }
            }
        }
        try? p.run()
    }
}
