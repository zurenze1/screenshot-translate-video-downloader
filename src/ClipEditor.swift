// 片段截取：在视频里挑一段（比如博主好看的动效），按原画质导出；可以框选水印抹掉
import Cocoa
import AVKit
import AVFoundation

// MARK: - 框选水印用的透明层

final class MarqueeView: NSView {
    var selecting = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var rect: CGRect? { didSet { needsDisplay = true; onChange?() } }
    var onChange: (() -> Void)?
    private var start: CGPoint?

    // 不在框选时，鼠标直接穿透给下面的播放器
    override func hitTest(_ p: NSPoint) -> NSView? { selecting ? super.hitTest(p) : nil }
    override func resetCursorRects() { if selecting { addCursorRect(bounds, cursor: .crosshair) } }

    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); rect = nil }
    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        let p = convert(e.locationInWindow, from: nil)
        rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
    }
    override func mouseUp(with e: NSEvent) {
        start = nil
        if let r = rect, r.width < 6 || r.height < 6 { rect = nil }
        selecting = false
        onChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if selecting {
            NSColor(white: 0, alpha: 0.25).setFill(); bounds.fill()
            let s = "按住鼠标拖出一个框，盖住水印" as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]
            let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.maxY - sz.height - 16), withAttributes: a)
        }
        guard let r = rect else { return }
        NSColor.systemRed.withAlphaComponent(0.22).setFill()
        r.fill()
        let p = NSBezierPath(rect: r)
        p.lineWidth = 2
        p.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        p.stroke()
    }
}

/// 整个窗口都能接住拖进来的视频文件
final class DropContainer: NSView {
    var onDrop: ((URL) -> Void)?
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { fileURL(s) != nil ? .copy : [] }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let u = fileURL(s) else { return false }
        onDrop?(u); return true
    }
    private func fileURL(_ s: NSDraggingInfo) -> URL? {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
            .first { ClipEditor.isVideo($0) }
    }
}

// MARK: - 片段截取窗口

final class ClipEditor: NSObject, NSWindowDelegate {
    static let shared = ClipEditor()
    /// 由 App 设置：把网页链接交给视频下载，下好后回调本地文件
    static var download: ((URL, @escaping (URL) -> Void) -> Void)?

    static func isVideo(_ u: URL) -> Bool {
        ["mp4", "mov", "m4v", "mkv", "webm", "flv", "avi", "ts"].contains(u.pathExtension.lowercased())
    }

    static let folder: URL = {
        let d = DownloaderController.folder.appendingPathComponent("片段", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    let window: NSWindow
    private let playerView = AVPlayerView()
    private let marquee = MarqueeView()
    private let linkField = NSTextField()
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let lengthLabel = NSTextField(labelWithString: "")
    private let format = NSPopUpButton(frame: .zero, pullsDown: false)
    private let eraseCheck = NSButton(checkboxWithTitle: "抹掉框里的水印", target: nil, action: nil)
    private let audioCheck = NSButton(checkboxWithTitle: "保留声音", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出片段", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var keyMonitor: Any?
    private var boundaryObserver: Any?

    private var source: URL?
    private var duration: Double = 0
    private var videoSize = CGSize.zero          // 显示方向下的像素尺寸
    private var startT: Double = 0
    private var endT: Double = 0
    private var exporting: Process?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "片段截取 · 原画质"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 520)
        window.delegate = self
        window.center()
        buildUI()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.window.isKeyWindow, self.source != nil,
                  !(self.window.firstResponder is NSTextView) else { return e }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "i": self.markStart(); return nil
            case "o": self.markEnd(); return nil
            case " ": self.togglePlay(); return nil
            default: return e
            }
        }
    }

    // MARK: 界面

    private func buildUI() {
        let root = DropContainer()
        root.registerForDraggedTypes([.fileURL])
        root.onDrop = { [weak self] u in self?.open(u) }
        window.contentView = root

        linkField.placeholderString = "粘贴视频链接（抖音 / B站 / YouTube…）或本地文件路径，回车载入；也可以直接把视频文件拖进窗口"
        linkField.target = self; linkField.action = #selector(loadFromField)
        let load = NSButton(title: "载入", target: self, action: #selector(loadFromField))
        let openBtn = NSButton(title: "打开视频文件…", target: self, action: #selector(openFile))
        let top = NSStackView(views: [linkField, load, openBtn])
        linkField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        playerView.controlsStyle = .inline
        playerView.showsFrameSteppingButtons = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        let stage = NSView()
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        stage.addSubview(playerView)
        marquee.translatesAutoresizingMaskIntoConstraints = false
        marquee.onChange = { [weak self] in self?.refresh() }
        stage.addSubview(marquee)
        hint.stringValue = "看到好看的动效，想只要其中一段？\n\n1. 上面粘贴视频链接回车（会先按原画质下载），或把本地视频拖进来\n2. 播放到开始的地方按「设为起点」（或键盘 I），到结束的地方按「设为终点」（或 O）\n3. 有水印就点「框选水印」在画面上框住它\n4. 点「导出片段」——默认逐帧精确、接近无损的画质"
        hint.textColor = NSColor(white: 0.85, alpha: 1)
        hint.font = .systemFont(ofSize: 14)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(hint)
        for v in [playerView, marquee] as [NSView] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: stage.leadingAnchor), v.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                v.topAnchor.constraint(equalTo: stage.topAnchor), v.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: stage.centerXAnchor), hint.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor, constant: -60),
        ])

        func button(_ t: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel); b.bezelStyle = .rounded; return b
        }
        for f in [startField, endField] {
            f.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            f.alignment = .center
            f.target = self; f.action = #selector(timesEdited)
            f.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }
        lengthLabel.textColor = .secondaryLabelColor
        lengthLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let row1 = NSStackView(views: [button("设为起点 (I)", #selector(markStart)), startField,
                                       button("设为终点 (O)", #selector(markEnd)), endField, lengthLabel, flex(),
                                       button("▶︎ 播放这一段", #selector(playRange))])

        eraseCheck.target = self; eraseCheck.action = #selector(optionsChanged)
        audioCheck.state = .on
        let row2 = NSStackView(views: [button("框选水印", #selector(beginMarquee)), button("清除框", #selector(clearMarquee)),
                                       eraseCheck, flex(), audioCheck])

        format.addItems(withTitles: ["精确到帧 · 接近无损（H.264 MP4，推荐）",
                                     "原画质无损 · 极快（直接拷贝原视频，起点会对齐到最近的关键帧）",
                                     "ProRes 422 HQ（MOV，剪辑软件里最流畅，体积大）"])
        format.selectItem(at: UserDefaults.standard.integer(forKey: "clipFormat"))
        format.target = self; format.action = #selector(optionsChanged)
        exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"
        exportButton.target = self; exportButton.action = #selector(exportClip)
        let row3 = NSStackView(views: [format, flex(), button("打开片段文件夹", #selector(openFolder)), exportButton])

        bar.style = .bar; bar.minValue = 0; bar.maxValue = 1; bar.isIndeterminate = false; bar.isHidden = true
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row4 = NSStackView(views: [status, bar])

        let stack = NSStackView(views: [top, stage, row1, row2, row3, row4])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for v in [top, stage, row1, row2, row3, row4] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stage.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        bar.widthAnchor.constraint(equalToConstant: 220).isActive = true
        refresh()
    }

    private func flex() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return v
    }

    // MARK: 载入

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func open(_ url: URL) {
        show()
        stopPlayback()
        source = url
        hint.isHidden = true
        marquee.rect = nil
        status.stringValue = "正在读取：\(url.lastPathComponent)"
        let asset = AVURLAsset(url: url)
        playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        Task { @MainActor in
            let d = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            var size = CGSize.zero
            if let t = try? await asset.loadTracks(withMediaType: .video).first,
               let (ns, tf) = try? await t.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: ns).applying(tf)
                size = CGSize(width: abs(r.width), height: abs(r.height))
            }
            // 系统播放器放不了的格式（如 webm），用 ffprobe 读时长和尺寸
            if d <= 0 || size == .zero, let probed = ClipEditor.probe(url) {
                self.duration = probed.0; self.videoSize = probed.1
                self.status.stringValue = "这个格式系统播放器预览不了，可以直接在上面输入起止时间（如 1:23.5）再导出"
            } else {
                self.duration = d; self.videoSize = size
                self.status.stringValue = "\(url.lastPathComponent) · \(Int(size.width))×\(Int(size.height)) · \(ClipEditor.fmt(d))"
            }
            self.startT = 0
            self.endT = self.duration
            self.refresh()
        }
    }

    static func probe(_ url: URL) -> (Double, CGSize)? {
        guard let ffprobe = Tools.find("ffprobe") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration", "-of", "default=nw=1", url.path]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var w = 0.0, h = 0.0, d = 0.0
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            if kv[0] == "width" { w = v } else if kv[0] == "height" { h = v } else if kv[0] == "duration" { d = v }
        }
        return d > 0 ? (d, CGSize(width: w, height: h)) : nil
    }

    @objc private func openFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        p.directoryURL = DownloaderController.folder
        p.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let u = p.url { self?.open(u) }
        }
    }

    @objc private func loadFromField() {
        let t = linkField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let path = (t as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) { open(URL(fileURLWithPath: path)); return }
        guard let u = LinkParser.firstURL(in: t) else { NSSound.beep(); return }
        linkField.stringValue = ""
        status.stringValue = "正在按原画质下载，下完自动打开…（进度在「视频下载」窗口）"
        ClipEditor.download?(u) { [weak self] file in self?.open(file) }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: 起止点

    private var currentTime: Double { playerView.player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0 }

    @objc private func markStart() {
        startT = min(max(0, currentTime), duration)
        if endT <= startT { endT = duration }
        refresh()
    }

    @objc private func markEnd() {
        endT = min(max(0, currentTime), duration)
        if endT <= startT { startT = 0 }
        refresh()
    }

    @objc private func timesEdited() {
        if let s = ClipEditor.parse(startField.stringValue) { startT = min(max(0, s), duration) }
        if let e = ClipEditor.parse(endField.stringValue) { endT = min(max(0, e), duration) }
        if endT <= startT { endT = duration }
        refresh()
    }

    private func togglePlay() {
        guard let p = playerView.player else { return }
        p.rate == 0 ? p.play() : p.pause()
    }

    @objc private func playRange() {
        guard let p = playerView.player, endT > startT else { return }
        stopPlayback()
        p.seek(to: CMTime(seconds: startT, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            self.boundaryObserver = p.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: self.endT, preferredTimescale: 600))],
                                                              queue: .main) { [weak self] in self?.stopPlayback() }
            p.play()
        }
    }

    private func stopPlayback() {
        playerView.player?.pause()
        if let o = boundaryObserver { playerView.player?.removeTimeObserver(o); boundaryObserver = nil }
    }

    // MARK: 水印框

    @objc private func beginMarquee() {
        guard source != nil else { return }
        playerView.player?.pause()
        marquee.selecting = true
    }

    @objc private func clearMarquee() { marquee.rect = nil; eraseCheck.state = .off; refresh() }

    @objc private func optionsChanged() {
        UserDefaults.standard.set(format.indexOfSelectedItem, forKey: "clipFormat")
        refresh()
    }

    /// 屏幕上画的框 → 视频像素坐标
    private func logoRect() -> CGRect? {
        guard let r = marquee.rect, videoSize.width > 0 else { return nil }
        let vb = playerView.videoBounds
        guard vb.width > 0, vb.height > 0 else { return nil }
        let x = (r.minX - vb.minX) / vb.width * videoSize.width
        let y = (vb.maxY - r.maxY) / vb.height * videoSize.height
        let w = r.width / vb.width * videoSize.width
        let h = r.height / vb.height * videoSize.height
        // delogo 要求框完全在画面里，且离边至少 1 像素
        let X = max(1, min(x, videoSize.width - 4)), Y = max(1, min(y, videoSize.height - 4))
        let W = max(2, min(w - (X - x), videoSize.width - X - 1)), H = max(2, min(h - (Y - y), videoSize.height - Y - 1))
        return CGRect(x: X.rounded(), y: Y.rounded(), width: W.rounded(), height: H.rounded())
    }

    private func refresh() {
        startField.stringValue = ClipEditor.fmt(startT)
        endField.stringValue = ClipEditor.fmt(endT)
        lengthLabel.stringValue = source == nil ? "" : String(format: "共 %.2f 秒", max(0, endT - startT))
        if marquee.rect != nil && eraseCheck.state == .off && !marquee.selecting { eraseCheck.state = .on }
        eraseCheck.isEnabled = marquee.rect != nil
        exportButton.isEnabled = source != nil && endT > startT && exporting == nil
        if eraseCheck.state == .on && marquee.rect != nil && format.indexOfSelectedItem == 1 {
            status.stringValue = "抹水印需要重新编码：会自动改用「精确到帧 · 接近无损」"
        }
    }

    // MARK: 导出

    @objc private func openFolder() { NSWorkspace.shared.open(ClipEditor.folder) }

    @objc private func exportClip() {
        guard let src = source, endT > startT, exporting == nil else { return }
        guard let ffmpeg = Tools.ffmpeg else {
            status.stringValue = "需要 ffmpeg 才能截取（可以用 Homebrew 安装：brew install ffmpeg）"; return
        }
        stopPlayback()
        let logo = eraseCheck.state == .on ? logoRect() : nil
        var mode = format.indexOfSelectedItem
        if mode == 1 && logo != nil { mode = 0 }
        let dur = endT - startT
        let base = DownloaderController.safeName(src.deletingPathExtension().lastPathComponent.replacingOccurrences(of: #"\s*\[[^\]]+\]$"#, with: "", options: .regularExpression))
        let tag = "\(ClipEditor.fmt(startT))-\(ClipEditor.fmt(endT))".replacingOccurrences(of: ":", with: ".")
        let ext = mode == 2 ? "mov" : (mode == 1 ? (src.pathExtension.isEmpty ? "mp4" : src.pathExtension) : "mp4")
        var out = ClipEditor.folder.appendingPathComponent("\(base) 片段 \(tag).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = ClipEditor.folder.appendingPathComponent("\(base) 片段 \(tag) (\(n)).\(ext)"); n += 1
        }

        var args = ["-hide_banner", "-nostdin", "-y", "-ss", String(format: "%.3f", startT), "-i", src.path,
                    "-t", String(format: "%.3f", dur), "-map", "0:v:0"]
        if audioCheck.state == .on { args += ["-map", "0:a:0?"] }
        switch mode {
        case 1:
            args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        case 2:
            if let l = logo { args += ["-vf", "delogo=x=\(Int(l.minX)):y=\(Int(l.minY)):w=\(Int(l.width)):h=\(Int(l.height))"] }
            args += ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-vendor", "apl0"]
            if audioCheck.state == .on { args += ["-c:a", "pcm_s16le"] }
        default:
            if let l = logo { args += ["-vf", "delogo=x=\(Int(l.minX)):y=\(Int(l.minY)):w=\(Int(l.width)):h=\(Int(l.height))"] }
            args += ["-c:v", "libx264", "-crf", "12", "-preset", "slow", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
            if audioCheck.state == .on { args += ["-c:a", "aac", "-b:a", "320k"] }
        }
        if mode != 2 { args += ["-movflags", "+faststart"] }
        args += ["-progress", "pipe:1", "-nostats", out.path]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        let pipe = Pipe(), err = Pipe()
        p.standardOutput = pipe
        p.standardError = err
        var errTail = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            if let r = s.range(of: #"out_time_us=(\d+)"#, options: .regularExpression),
               let us = Double(s[r].split(separator: "=")[1]) {
                DispatchQueue.main.async { self?.bar.doubleValue = min(1, us / 1_000_000 / dur) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            errTail = String((errTail + String(decoding: d, as: UTF8.self)).suffix(400))
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.exporting = nil
                self.bar.isHidden = true
                if proc.terminationStatus == 0 {
                    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                    self.status.stringValue = "✅ 已导出：\(out.lastPathComponent)（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）"
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                } else {
                    let last = errTail.split(separator: "\n").last.map(String.init) ?? ""
                    self.status.stringValue = "导出失败：\(last)"
                }
                self.refresh()
            }
        }
        do {
            try p.run()
            exporting = p
            bar.doubleValue = 0
            bar.isHidden = false
            status.stringValue = mode == 1 ? "正在拷贝原画质片段…" : "正在高画质导出\(logo != nil ? "（同时抹掉水印）" : "")…"
            refresh()
        } catch {
            status.stringValue = "导出失败：\(error.localizedDescription)"
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopPlayback()
        exporting?.terminate()
    }

    // MARK: 时间格式 1:23.45

    static func fmt(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return m >= 60 ? String(format: "%d:%02d:%05.2f", m / 60, m % 60, s) : String(format: "%d:%05.2f", m, s)
    }

    static func parse(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "：", with: ":").split(separator: ":")
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return parts.isEmpty ? nil : total
    }
}
