// 工具箱 —— 菜单栏常驻的翻译 + 中转站 + 视频下载小工具
// ⌥D 翻译选中文字   ⌥S 截图识别并翻译   ⌥A 打开输入框翻译   ⌥V 视频下载
import Cocoa
import Carbon
import Vision
import AVFoundation
import ServiceManagement

// MARK: - 全局快捷键（Carbon，无需额外权限）

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        if !installed { install() }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5A52_5A54), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    private func install() {
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - 读取任意软件里选中的文字

enum SelectionReader {
    /// 先用辅助功能接口直接读（原生软件大多支持，不碰剪贴板）
    static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let element = f as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &value) == .success,
              let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 读不到时模拟 ⌘C 复制，读完把剪贴板原样还原
    static func copySelection(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postCommandC()
        var tries = 0
        func poll() {
            tries += 1
            if pb.changeCount != before {
                let s = pb.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                restore(pb, saved)
                completion((s?.isEmpty ?? true) ? nil : s)
            } else if tries < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            } else {
                completion(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { poll() }
    }

    static func postCommandC() { postKey(kVK_ANSI_C) }

    static func postKey(_ code: Int, command: Bool = true) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(code)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        // 明确只带 ⌘，避免用户还按着 ⌥ 变成 ⌘⌥C
        down?.flags = command ? .maskCommand : []
        up?.flags = command ? .maskCommand : []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
    }

    static func restore(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { dict in
            let it = NSPasteboardItem()
            for (t, d) in dict { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

// MARK: - 截图识别文字（系统自带的 Vision，离线）

enum ScreenOCR {
    static func captureAndRecognize(completion: @escaping (String?) -> Void) {
        let path = NSTemporaryDirectory() + "zrz_ocr_\(UUID().uuidString).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", path]
        p.terminationHandler = { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? FileManager.default.removeItem(atPath: path) }
                guard FileManager.default.fileExists(atPath: path),
                      let img = NSImage(contentsOfFile: path),
                      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { DispatchQueue.main.async { completion(nil) }; return }
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.recognitionLanguages = ["en-US"]
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
                let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let text = mergeLines(lines)
                DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
            }
        }
        do { try p.run() } catch { completion(nil) }
    }

    /// 把被换行截断的同一句话拼回去，翻译更通顺
    static func mergeLines(_ lines: [String]) -> String {
        var out = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if out.isEmpty { out = line; continue }
            let last = out.last!
            let firstLower = line.first.map { $0.isLowercase } ?? false
            if last == "-" {
                out.removeLast(); out += line
            } else if !".!?:;。！？：；".contains(last) && firstLower {
                out += " " + line
            } else {
                out += "\n" + line
            }
        }
        return out
    }
}

// MARK: - 翻译浮窗

/// 原文输入框：粘贴或拖进图片时，识别图上的字
final class SourceTextView: NSTextView {
    var onImage: ((CGImage) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("在这里粘贴文字，或拖入一张截图…" as NSString).draw(at: NSPoint(x: 13, y: 11), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ProductTheme.muted.withAlphaComponent(0.7)])
        }
    }

    private func image(from pb: NSPasteboard) -> CGImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first(where: { ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"].contains($0.pathExtension.lowercased()) }),
           let img = NSImage(contentsOf: u) {
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        // 剪贴板里只有图片（比如 ⌘⌃⇧4 截到剪贴板）才识别；有文字时按文字粘贴
        if pb.string(forType: .string) == nil, pb.availableType(from: [.png, .tiff]) != nil, let img = NSImage(pasteboard: pb) {
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
    }

    override func paste(_ sender: Any?) {
        if let cg = image(from: .general) { onImage?(cg); return }
        pasteAsPlainText(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        image(from: sender.draggingPasteboard) != nil ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let cg = image(from: sender.draggingPasteboard) { onImage?(cg); return true }
        return super.performDragOperation(sender)
    }
}

final class PanelController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let panel: NSPanel
    private let sourceScroll: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        let tv = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 92))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.registerForDraggedTypes([.png, .tiff, .fileURL])
        sv.documentView = tv
        return sv
    }()
    private var autoWork: DispatchWorkItem?
    private let resultScroll = NSTextView.scrollableTextView()
    private var sourceView: NSTextView { sourceScroll.documentView as! NSTextView }
    private var resultView: NSTextView { resultScroll.documentView as! NSTextView }
    private let statusLabel = NSTextField(labelWithString: "")
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pinButton = NSButton(title: "固定", target: nil, action: nil)
    private let speakButton = NSButton(title: "朗读原文", target: nil, action: nil)
    private var pinned = false
    private var previousApp: NSRunningApplication?
    private var task: Task<Void, Never>?
    private let speech = AVSpeechSynthesizer()
    private var keyMonitor: Any?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "翻译"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 480, height: 540)
        panel.delegate = self
        buildUI()
        ProductTheme.apply(to: panel)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.panel.isKeyWindow else { return e }
            if e.keyCode == 53 { self.closeAndReturn(); return nil }                    // Esc
            if e.keyCode == 36 && e.modifierFlags.contains(.command) { self.translate(); return nil } // ⌘↩
            return e
        }
    }

    private func buildUI() {
        let content = panel.contentView!
        let header = ProductTheme.header("01 / 即时翻译", "看懂，再继续。", "粘贴文字或拖入图片，自动中英互译。")
        let sourceLabel = ProductTheme.label("原文  /  粘贴即译")
        let resultLabel = ProductTheme.label("译文")

        sourceView.font = .systemFont(ofSize: 14)
        sourceView.textColor = ProductTheme.ink
        sourceView.isRichText = false
        sourceView.allowsUndo = true
        sourceView.textContainerInset = NSSize(width: 12, height: 10)
        sourceView.backgroundColor = ProductTheme.surface
        sourceScroll.borderType = .bezelBorder
        sourceView.delegate = self
        (sourceView as? SourceTextView)?.onImage = { [weak self] cg in self?.translateImage(cg) }

        resultView.font = .systemFont(ofSize: 17)
        resultView.isEditable = false
        resultView.isSelectable = true
        resultView.isRichText = false
        resultView.textContainerInset = NSSize(width: 12, height: 10)
        resultView.drawsBackground = false
        resultScroll.drawsBackground = false
        resultScroll.borderType = .noBorder

        enginePopup.addItems(withTitles: ["自动（离线→必应→谷歌）"] + Engine.allCases.map { $0.name })
        enginePopup.selectItem(at: UserDefaults.standard.integer(forKey: "engineIndex2"))
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        enginePopup.controlSize = .small

        let translateButton = NSButton(title: "重新翻译", target: self, action: #selector(translateClicked))
        translateButton.toolTip = "粘贴或打字后会自动翻译；也可以把截图粘贴（⌘V）或拖进上面的框，自动识别图上的字再翻译"
        speakButton.target = self; speakButton.action = #selector(speak)
        let copyButton = NSButton(title: "复制译文", target: self, action: #selector(copyResult))
        ProductTheme.primary(copyButton)
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.target = self; pinButton.action = #selector(togglePin)
        for b in [translateButton, speakButton, copyButton, pinButton] {
            b.bezelStyle = .rounded; b.controlSize = .small
        }
        translateButton.keyEquivalent = ""

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        func spacer() -> NSView {
            let v = NSView()
            v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            return v
        }
        let row1 = NSStackView(views: [speakButton, translateButton, spacer(), enginePopup])
        row1.orientation = .horizontal
        row1.distribution = .fill
        let row2 = NSStackView(views: [statusLabel, spacer(), copyButton, pinButton])
        row2.orientation = .horizontal
        row2.distribution = .fill

        let stack = NSStackView(views: [header, sourceLabel, sourceScroll, row1, resultLabel, resultScroll, row2])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [header, sourceScroll, row1, resultScroll, row2] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        sourceScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        resultScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        for v in [header, sourceLabel, resultLabel, row1, row2, sourceScroll] as [NSView] {
            v.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }
    }

    // 显示浮窗。text 为 nil 表示进入输入模式
    func show(text: String?, hint: String? = nil) {
        if !panel.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? nil : front
            placeNearMouse()
        }
        sourceView.string = text ?? ""
        lastLength = sourceView.string.count
        resultView.string = hint ?? "输入、粘贴文字会自动翻译（中文→英文，其他→中文）。\n截图也可以直接 ⌘V 粘贴或拖进上面的框，自动识别图上的字。"
        statusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if text != nil {
            translate()
        } else {
            panel.makeFirstResponder(sourceView)
        }
    }

    private func placeNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        var x = mouse.x + 14
        var y = mouse.y - size.height - 14
        if x + size.width > vf.maxX { x = mouse.x - size.width - 14 }
        if y < vf.minY { y = mouse.y + 14 }
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func translate() {
        let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task?.cancel()
        resultView.string = "翻译中…"
        statusLabel.stringValue = ""
        let idx = enginePopup.indexOfSelectedItem
        let only: Engine? = idx == 0 ? nil : Engine(rawValue: idx - 1)
        let started = Date()
        task = Task { @MainActor [weak self] in
            do {
                let r = try await Translator.shared.translate(text, only: only)
                guard let self = self, !Task.isCancelled else { return }
                self.resultView.string = r.text
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                self.statusLabel.stringValue = "\(r.engine.name) · \(r.toChinese ? "外文→中文" : "中文→英文") · \(ms) 毫秒"
            } catch {
                guard let self = self, !Task.isCancelled else { return }
                self.resultView.string = "翻译没成功。\n\n\(error.localizedDescription)\n\n可以检查一下网络，或在右上角换一个翻译引擎再试。也可以在菜单栏「译」→「下载离线翻译包」，以后不联网也能秒翻。"
            }
        }
    }

    @objc private func translateClicked() { translate() }

    /// 打字、粘贴后停一下就自动翻译，不用再点按钮
    func textDidChange(_ notification: Notification) {
        autoWork?.cancel()
        let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { task?.cancel(); resultView.string = ""; statusLabel.stringValue = ""; return }
        let w = DispatchWorkItem { [weak self] in self?.translate() }
        autoWork = w
        // 一次粘进来很多字就马上翻；一个个打字时等停顿
        let pasted = text.count - lastLength > 3
        lastLength = text.count
        DispatchQueue.main.asyncAfter(deadline: .now() + (pasted ? 0.05 : 0.6), execute: w)
    }
    private var lastLength = 0

    /// 截图、图片：识别上面的字再翻译
    func translateImage(_ cg: CGImage) {
        task?.cancel()
        resultView.string = "正在识别图片里的文字…"
        statusLabel.stringValue = ""
        ImageOCR.text(of: cg) { [weak self] text in
            guard let self = self else { return }
            guard let t = text else { self.resultView.string = "这张图片上没有识别到文字。"; return }
            self.sourceView.string = t
            self.lastLength = t.count
            self.translate()
            self.statusLabel.stringValue = "已识别图片文字"
        }
    }

    @objc private func engineChanged() {
        UserDefaults.standard.set(enginePopup.indexOfSelectedItem, forKey: "engineIndex2")
        translate()
    }

    @objc private func speak() {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate); return }
        let text = sourceView.string
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Translator.isMostlyChinese(text) ? "zh-CN" : "en-US")
        speech.speak(u)
    }

    @objc private func copyResult() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(resultView.string, forType: .string)
        statusLabel.stringValue = "已复制译文"
    }

    @objc private func togglePin() {
        pinned = pinButton.state == .on
        pinButton.title = pinned ? "已固定" : "固定"
        ProductTheme.styleButton(pinButton)
    }

    private func closeAndReturn() {
        let back = previousApp
        panel.close()
        back?.activate(options: [])
    }

    func windowDidResignKey(_ notification: Notification) {
        if !pinned && panel.isVisible { panel.close() }
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
    }
}

// MARK: - 小提示（鼠标旁边，不抢焦点）

enum Toast {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = NSVisualEffectView()
            v.material = .popover
            v.appearance = NSAppearance(named: .aqua)
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            v.layer?.borderWidth = 1
            v.layer?.borderColor = ProductTheme.line.cgColor
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 13, weight: .medium)
            l.textColor = ProductTheme.ink
            l.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            p.contentView = v
            panel = p; label = l
        }
        guard let p = panel, let l = label else { return }
        l.stringValue = text
        let w = l.intrinsicContentSize.width + 28
        let m = NSEvent.mouseLocation
        p.setFrame(NSRect(x: m.x + 16, y: m.y - 40, width: w, height: 30), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { p.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

// MARK: - 菜单栏 & 应用入口

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var loginItem: NSMenuItem?
    private var screenTranslator: AnyObject?
    private var orbItem: NSMenuItem?
    private var shelf: ShelfController!
    private lazy var downloader = DownloaderController()
    private let watcher = ScreenshotWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController()
        Translator.shared.warmUp()
        buildMainMenu()
        shelf = ShelfController()
        shelf.onTranslate = { [weak self] text in
            if let t = text { self?.panel.show(text: t) }
            else { self?.panel.show(text: nil, hint: "这张图上没有识别到文字。") }
        }
        watcher.start()
        if #available(macOS 14.0, *) {
            let st = ToolboxHubController()
            st.onTranslateField = { [weak self] in self?.translateFocusedField() }
            st.onOpenPanel = { [weak self] in self?.inputTranslate() }
            st.onOpenShelf = { [weak self] in self?.shelf.toggle() }
            st.onOpenDownloader = { [weak self] link in self?.downloader.show(link: link) }
            st.onOpenClip = { ClipEditor.shared.show() }
            shelf.anchorFrame = { [weak st] in st?.orbVisible == true ? st?.orbFrame : nil }
            st.setBadge(ShelfStore.shared.items.count)
            ShelfStore.shared.observe { [weak st] in st?.setBadge(ShelfStore.shared.items.count) }
            screenTranslator = st
            if !UserDefaults.standard.bool(forKey: "orbHidden") { st.showOrb() }
        }
        buildStatusItem()

        let opt = Int(optionKey)
        var failed: [String] = []
        if !HotKeyCenter.shared.register(id: 1, keyCode: kVK_ANSI_D, modifiers: opt, handler: { [weak self] in self?.translateSelection() }) { failed.append("⌥D") }
        if !HotKeyCenter.shared.register(id: 2, keyCode: kVK_ANSI_S, modifiers: opt, handler: { [weak self] in self?.translateScreen() }) { failed.append("⌥S") }
        if !HotKeyCenter.shared.register(id: 3, keyCode: kVK_ANSI_A, modifiers: opt, handler: { [weak self] in self?.inputTranslate() }) { failed.append("⌥A") }
        if !HotKeyCenter.shared.register(id: 5, keyCode: kVK_ANSI_E, modifiers: opt, handler: { [weak self] in self?.translateFocusedField() }) { failed.append("⌥E") }
        if !HotKeyCenter.shared.register(id: 6, keyCode: kVK_ANSI_X, modifiers: opt, handler: { ShelfShooter.shoot() }) { failed.append("⌥X") }
        if !HotKeyCenter.shared.register(id: 7, keyCode: kVK_ANSI_Z, modifiers: opt, handler: { [weak self] in self?.shelf.toggle() }) { failed.append("⌥Z") }
        if !HotKeyCenter.shared.register(id: 8, keyCode: kVK_ANSI_V, modifiers: opt, handler: { [weak self] in self?.downloader.show() }) { failed.append("⌥V") }
        if !HotKeyCenter.shared.register(id: 9, keyCode: kVK_ANSI_C, modifiers: opt, handler: { ClipEditor.shared.show() }) { failed.append("⌥C") }
        if !failed.isEmpty {
            alert("有快捷键被别的软件占用了：\(failed.joined(separator: "、"))", "可以先用菜单栏「译」里的菜单项。")
        }

        let d = UserDefaults.standard
        if !d.bool(forKey: "launchedBefore") {
            d.set(true, forKey: "launchedBefore")
            setLoginItem(true)
            if !AXIsProcessTrusted() { requestAccessibility() }
            panel.show(text: "Welcome! Select any English text in any app and press Option + D to translate it.")
        }
        refreshLoginItemState()
        if !d.bool(forKey: "creamGoldIntroduced"), #available(macOS 14.0, *), let st = screenTranslator as? ToolboxHubController, st.orbVisible {
            d.set(true, forKey: "creamGoldIntroduced")
            st.toggleTools()
        }
    }

    private func buildMainMenu() {
        // 让输入框里的 ⌘C / ⌘V / ⌘A / ⌘Z 生效
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出工具箱", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let toolsItem = NSMenuItem(title: "工具", action: nil, keyEquivalent: "")
        let tools = NSMenu(title: "工具")
        for (title, action) in [("打开工具箱", #selector(menuToolbox)), ("翻译框", #selector(menuInput)), ("中转站", #selector(menuShelf)), ("视频下载", #selector(menuDownload)), ("片段截取", #selector(menuClip))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; tools.addItem(item)
        }
        tools.addItem(.separator())
        for (title, action) in [("自媒体工作台", #selector(menuWorkbench)), ("添加工具…", #selector(menuAddTool))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; tools.addItem(item)
        }
        toolsItem.submenu = tools; main.addItem(toolsItem)
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.title = "工具箱"
            b.font = .systemFont(ofSize: 14, weight: .semibold)
            b.toolTip = "工具箱：翻译 · 中转站 · 视频下载"
        }
        let m = NSMenu()
        m.delegate = self
        func add(_ title: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            m.addItem(it)
            return it
        }
        _ = add("打开工具箱", #selector(menuToolbox))
        _ = add("自媒体工作台", #selector(menuWorkbench))
        _ = add("添加工具…", #selector(menuAddTool))
        m.addItem(.separator())
        _ = add("输入框：中文 → 英文", #selector(menuField), "e", .option)
        _ = add("中转站", #selector(menuShelf), "z", .option)
        _ = add("截一张存进中转站", #selector(menuShoot), "x", .option)
        _ = add("视频下载（无水印原画质）", #selector(menuDownload), "v", .option)
        _ = add("片段截取（原画质 / 去水印）", #selector(menuClip), "c", .option)
        orbItem = add("显示桌面悬浮入口", #selector(toggleOrb))
        m.addItem(.separator())
        _ = add("翻译选中文字", #selector(menuSelection), "d", .option)
        _ = add("截图翻译", #selector(menuScreen), "s", .option)
        _ = add("输入翻译", #selector(menuInput), "a", .option)
        m.addItem(.separator())
        loginItem = add("开机自动启动", #selector(toggleLogin))
        _ = add("打开权限设置…", #selector(openPermissions))
        _ = add("使用说明", #selector(showHelp))
        m.addItem(.separator())
        _ = add("退出", #selector(quit), "q")
        statusItem.menu = m
    }

    @objc private func toggleOrb() {
        guard #available(macOS 14.0, *), let st = screenTranslator as? ToolboxHubController else { return }
        let hide = st.orbVisible
        if hide { st.hideOrb() } else { st.showOrb() }
        UserDefaults.standard.set(hide, forKey: "orbHidden")
    }

    func menuWillOpen(_ menu: NSMenu) {
        if #available(macOS 14.0, *), let st = screenTranslator as? ToolboxHubController {
            orbItem?.state = st.orbVisible ? .on : .off

        }
    }

    // 菜单点击时稍等菜单收起，焦点回到原来的软件
    @objc private func menuSelection() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.translateSelection() } }
    @objc private func menuScreen() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.translateScreen() } }
    @objc private func menuInput() { inputTranslate() }

    func translateSelection() {
        guard AXIsProcessTrusted() else {
            requestAccessibility()
            panel.show(text: nil, hint: "要读取别的软件里选中的文字，需要先在「系统设置 → 隐私与安全性 → 辅助功能」里打开「工具箱」。\n\n现在也可以直接在上面的框里输入或粘贴英文。")
            return
        }
        if let s = SelectionReader.axSelectedText() { panel.show(text: s); return }
        SelectionReader.copySelection { [weak self] s in
            if let s = s { self?.panel.show(text: s) }
            else { self?.panel.show(text: nil, hint: "没有读到选中的文字。\n\n可以直接在上面的框里输入或粘贴；图片、视频、按钮上的英文用 ⌥S 截图翻译。") }
        }
    }

    func translateScreen() {
        ScreenOCR.captureAndRecognize { [weak self] text in
            guard let text = text else { return }   // 按了 Esc 或没识别出文字
            self?.panel.show(text: text)
        }
    }

    func inputTranslate() { panel.show(text: nil) }

    @objc private func menuShelf() { shelf.toggle() }
    @objc private func menuDownload() { downloader.show() }
    @objc private func menuClip() { ClipEditor.shared.show() }
    @objc private func menuWorkbench() { CompanionTool.workbench.open() }
    @objc private func menuAddTool() { ToolboxLinks.shared.promptToAdd() }
    @objc private func menuToolbox() {
        if #available(macOS 14.0, *), let st = screenTranslator as? ToolboxHubController { st.toggleTools() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true
    }

    @objc private func menuShoot() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { ShelfShooter.shoot() } }

    @objc private func menuField() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.translateFocusedField() } }

    /// 把当前输入框里打的中文换成英文：有选中就只换选中的部分，没有选中就换整个输入框
    func translateFocusedField() {
        guard AXIsProcessTrusted() else {
            requestAccessibility()
            panel.show(text: nil, hint: "要改写别的软件输入框里的字，需要先在「系统设置 → 隐私与安全性 → 辅助功能」里打开「工具箱」。")
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            panel.show(text: nil, hint: "先点一下要打字的输入框（搜索框、聊天框都行），打好中文后再按 ⌥E。\n\n也可以直接在上面的框里输入中文，按 ⌘↩ 翻成英文。")
            return
        }
        let hasSelection = SelectionReader.axSelectedText() != nil
        if !hasSelection {
            SelectionReader.postKey(kVK_ANSI_A)   // 全选输入框
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            SelectionReader.copySelection { [weak self] text in
                guard let self = self else { return }
                guard let text = text, Translator.isMostlyChinese(text) else {
                    if !hasSelection { SelectionReader.postKey(kVK_RightArrow, command: false) }   // 取消全选
                    NSSound.beep()
                    return
                }
                Toast.show("翻译中…")
                Task { @MainActor in
                    do {
                        let r = try await Translator.shared.translate(text, only: nil)
                        let pb = NSPasteboard.general
                        let saved = SelectionReader.snapshot(pb)
                        pb.clearContents()
                        pb.setString(r.text, forType: .string)
                        SelectionReader.postKey(kVK_ANSI_V)   // 粘贴替换
                        Toast.show("已换成英文（⌘Z 可撤销）")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { SelectionReader.restore(pb, saved) }
                    } catch {
                        Toast.show("翻译没成功，请检查网络")
                    }
                }
            }
        }
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @objc private func openPermissions() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc private func toggleLogin() {
        setLoginItem(loginItem?.state != .on)
        refreshLoginItemState()
    }

    private func setLoginItem(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("login item: \(error)") }
        }
    }

    private func refreshLoginItemState() {
        if #available(macOS 13.0, *) {
            loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginItem?.isEnabled = false
        }
    }

    @objc private func showHelp() {
        alert("工具箱 · 用法", "点桌面悬浮入口选择翻译框、中转站、视频下载和片段截取。文件拖入中转站会保存副本；自媒体工作台需另行安装。可用添加工具收录本机应用或网页。")
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
