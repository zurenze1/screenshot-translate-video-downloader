// 片段截取：看视频时看到好看的动效，只把那几秒按原画质存下来
// 链接不用整个下载：在线预览，选好起止点后只下载这一段；可以自动找水印 / 手动框选水印一起抹掉
import Cocoa
import AVKit
import AVFoundation

// MARK: - 水印框（比例坐标，跟着画面缩放）

final class MarqueeView: NSView {
    var selecting = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// 水印框，0~1 比例，原点在画面左上
    var fracRects: [CGRect] = [] { didSet { needsDisplay = true } }
    /// 画面在本视图里实际显示的区域
    var videoBounds: () -> CGRect = { .zero }
    var onAdd: ((CGRect) -> Void)?
    private var start: CGPoint?
    private var dragging: CGRect?

    override func hitTest(_ p: NSPoint) -> NSView? { selecting ? super.hitTest(p) : nil }
    override func resetCursorRects() { if selecting { addCursorRect(bounds, cursor: .crosshair) } }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); needsDisplay = true }

    private func toView(_ f: CGRect) -> CGRect {
        let vb = videoBounds()
        return CGRect(x: vb.minX + f.minX * vb.width, y: vb.maxY - (f.minY + f.height) * vb.height,
                      width: f.width * vb.width, height: f.height * vb.height)
    }

    private func toFrac(_ r: CGRect) -> CGRect? {
        let vb = videoBounds()
        guard vb.width > 0, vb.height > 0 else { return nil }
        let c = r.intersection(vb)
        guard !c.isNull, c.width > 3, c.height > 3 else { return nil }
        return CGRect(x: (c.minX - vb.minX) / vb.width, y: (vb.maxY - c.maxY) / vb.height,
                      width: c.width / vb.width, height: c.height / vb.height)
    }

    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil) }
    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        let p = convert(e.locationInWindow, from: nil)
        dragging = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if let r = dragging, let f = toFrac(r) { onAdd?(f) }
        start = nil; dragging = nil
        selecting = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if selecting {
            NSColor(white: 0, alpha: 0.25).setFill(); bounds.fill()
            let s = "按住鼠标拖出一个框，盖住水印（可以框好几个）" as NSString
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]
            let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.maxY - sz.height - 16), withAttributes: a)
        }
        for r in fracRects.map(toView) + (dragging.map { [$0] } ?? []) {
            NSColor.systemRed.withAlphaComponent(0.22).setFill()
            r.fill()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 2
            p.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.setStroke()
            p.stroke()
        }
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

// MARK: - 在线预览：B站、YouTube 的画面是分段 MP4（.m4s），系统播放器要整个读一遍才能播。
// 这里读出文件开头的分段索引（sidx），拼成 HLS 播放列表交给播放器，拖到哪就只取哪一段

enum HLSPreview {
    struct Track { let url: URL; let codec: String }

    /// 读分段 MP4 开头，返回 (头部长度, [(偏移, 大小, 秒数)])
    static func segments(_ url: URL, headers: [String: String]) async throws -> (Int, [(Int, Int, Double)]) {
        var r = URLRequest(url: url)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        r.timeoutInterval = 15
        let (d, _) = try await URLSession.shared.data(for: r)
        let b = [UInt8](d)
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func u64(_ i: Int) -> Int { u32(i) << 32 | u32(i + 4) }
        var i = 0
        while i + 8 <= b.count {
            let size = u32(i)
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            if type == "sidx" {
                guard i + size <= b.count else { break }
                let v = b[i + 8]
                // sidx：版本(1) 标志(3) 轨道号(4) 时间刻度(4) 起始时间 首段偏移 保留(2) 段数(2)
                let timescale = Double(max(1, u32(i + 16)))
                var p = i + 20
                var first: Int
                if v == 0 { first = u32(p + 4); p += 8 } else { first = u64(p + 8); p += 16 }
                guard p + 4 <= b.count else { break }
                p += 2
                let count = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                var off = i + size + first
                var segs: [(Int, Int, Double)] = []
                for _ in 0..<count {
                    let refSize = u32(p) & 0x7FFF_FFFF
                    let dur = Double(u32(p + 4)) / timescale
                    segs.append((off, refSize, dur))
                    off += refSize
                    p += 12
                }
                return (i, segs)
            }
            if size < 8 { break }
            i += size
        }
        throw TError(message: "不是分段格式")
    }

    static func mediaPlaylist(_ url: URL, initLen: Int, segs: [(Int, Int, Double)]) -> String {
        let target = Int((segs.map { $0.2 }.max() ?? 6).rounded(.up))
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n"
        s += "#EXT-X-MAP:URI=\"\(url.absoluteString)\",BYTERANGE=\"\(initLen)@0\"\n"
        for (off, size, dur) in segs {
            s += String(format: "#EXTINF:%.4f,\n", dur) + "#EXT-X-BYTERANGE:\(size)@\(off)\n\(url.absoluteString)\n"
        }
        return s + "#EXT-X-ENDLIST\n"
    }
}

/// 用自定义地址把播放列表交给系统播放器（播放列表在内存里，分段直接从网站取）
final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    var files: [String: String] = [:]
    let queue = DispatchQueue(label: "playlist-loader")

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard let name = req.request.url?.lastPathComponent, let text = files[name] else { return false }
        let data = Data(text.utf8)
        if let info = req.contentInformationRequest {
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        req.dataRequest?.respond(with: data)
        req.finishLoading()
        return true
    }

    /// 视频（可选加音频）→ 可以直接播放的 asset
    static func makeAsset(video: HLSPreview.Track, audio: HLSPreview.Track?, headers: [String: String]) async -> (AVURLAsset, PlaylistLoader)? {
        guard let (vInit, vSegs) = try? await HLSPreview.segments(video.url, headers: headers), !vSegs.isEmpty else { return nil }
        let loader = PlaylistLoader()
        loader.files["video.m3u8"] = HLSPreview.mediaPlaylist(video.url, initLen: vInit, segs: vSegs)
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        var codecs = video.codec
        var audioAttr = ""
        if let a = audio, let (aInit, aSegs) = try? await HLSPreview.segments(a.url, headers: headers), !aSegs.isEmpty {
            loader.files["audio.m3u8"] = HLSPreview.mediaPlaylist(a.url, initLen: aInit, segs: aSegs)
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"zrzhls://p/audio.m3u8\"\n"
            codecs += "," + a.codec
            audioAttr = ",AUDIO=\"a\""
        }
        master += "#EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS=\"\(codecs)\"\(audioAttr)\nzrzhls://p/video.m3u8\n"
        loader.files["master.m3u8"] = master
        let asset = AVURLAsset(url: URL(string: "zrzhls://p/master.m3u8")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }
}

// MARK: - 在线视频（不下载，直接预览）

struct RemoteVideo {
    let page: URL
    let title: String
    let preview: URL
    let previewCodec: String
    let audio: HLSPreview.Track?
    let duration: Double
    let headers: [String: String]
    let width: Int          // 最高画质的分辨率（抹水印时按它算像素）
    let height: Int
    let direct: URL?        // 抖音：直接就是无水印原文件地址

    static func fetch(_ link: URL) async throws -> RemoteVideo {
        if LinkParser.isDouyin(link) {
            let item = try await Douyin.resolve(link)
            guard let u = item.videoURLs.first else { throw TError(message: "这是图文作品，没有视频") }
            return RemoteVideo(page: link, title: item.title, preview: u, previewCodec: "", audio: nil, duration: 0,
                               headers: ["User-Agent": Douyin.mobileUA, "Referer": "https://www.douyin.com/"],
                               width: 0, height: 0, direct: u)
        }
        guard let ytdlp = Tools.ytdlp else { throw TError(message: "还没有下载组件，先在「视频下载」里下载一次任意视频，会自动安装") }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ytdlp)
            p.arguments = [link.absoluteString, "-J", "--no-playlist", "--no-warnings"] + Tools.commonArgs()
            p.environment = Tools.env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            DispatchQueue.global().async {
                let d = out.fileHandleForReading.readDataToEndOfFile()
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                if p.terminationStatus == 0 { cont.resume(returning: d) }
                else {
                    let line = e.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? ""
                    cont.resume(throwing: TError(message: DownloaderController.explain(line, link: link)))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TError(message: "读不到视频信息") }
        let formats = j["formats"] as? [[String: Any]] ?? []
        func s(_ f: [String: Any], _ k: String) -> String { f[k] as? String ?? "" }
        func h(_ f: [String: Any]) -> Int { f["height"] as? Int ?? 0 }
        let videos = formats.filter { let v = s($0, "vcodec"); return !v.isEmpty && v != "none" }
        let best = videos.max { h($0) < h($1) }
        // 预览：优先带声音的 mp4，其次只有画面的 H.264 mp4，再不行用 m3u8；预览画质 ≤1080p 就够
        let https = videos.filter { s($0, "protocol").hasPrefix("http") && s($0, "ext") == "mp4" && h($0) <= 1080 }
        let pick = https.filter { let a = s($0, "acodec"); return !a.isEmpty && a != "none" }.max { h($0) < h($1) }
            ?? https.filter { s($0, "vcodec").hasPrefix("avc") }.max { h($0) < h($1) }
            ?? https.max { h($0) < h($1) }
            ?? videos.filter { s($0, "protocol").contains("m3u8") }.max { h($0) < h($1) }
        guard let f = pick, let u = URL(string: s(f, "url")) else { throw TError(message: "这个网站的视频没法在线预览，可以先用「视频下载」下载下来再截") }
        let headers = (f["http_headers"] as? [String: String]) ?? (j["http_headers"] as? [String: String]) ?? [:]
        // 画面是分段格式时，再挑一路 m4a 声音给预览用
        let audios = formats.filter { s($0, "vcodec") == "none" && s($0, "acodec").hasPrefix("mp4a") && s($0, "protocol").hasPrefix("http") }
        let a = audios.max { ($0["abr"] as? Double ?? 0) < ($1["abr"] as? Double ?? 0) }
        let audio = a.flatMap { x in URL(string: s(x, "url")).map { HLSPreview.Track(url: $0, codec: s(x, "acodec")) } }
        let hasAudio = !(s(f, "acodec").isEmpty || s(f, "acodec") == "none")
        return RemoteVideo(page: link, title: j["title"] as? String ?? "视频", preview: u, previewCodec: s(f, "vcodec"),
                           audio: hasAudio ? nil : audio, duration: j["duration"] as? Double ?? 0, headers: headers,
                           width: best?["width"] as? Int ?? 0, height: best.map(h) ?? 0, direct: nil)
    }
}

// MARK: - 片段截取窗口

final class ClipEditor: NSObject, NSWindowDelegate {
    static let shared = ClipEditor()

    static func isVideo(_ u: URL) -> Bool {
        ["mp4", "mov", "m4v", "mkv", "webm", "flv", "avi", "ts"].contains(u.pathExtension.lowercased())
    }

    /// 片段保存位置：自己选的，或「视频保存位置/片段」
    static var folder: URL {
        let d = UserDefaults.standard.string(forKey: "clipFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? DownloaderController.folder.appendingPathComponent("片段", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

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
    private let undoButton = NSButton(title: "↶ 撤销", target: nil, action: nil)
    private let folderButton = NSButton(title: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var keyMonitor: Any?
    private var boundaryObserver: Any?

    // 当前视频：本地文件 或 在线视频
    private var source: URL?
    private var remote: RemoteVideo?
    private var playlistLoader: PlaylistLoader?
    private var duration: Double = 0
    private var videoSize = CGSize.zero
    private var startT: Double = 0
    private var endT: Double = 0
    private var exporting: Process?

    // 撤销
    private struct Snap { let start: Double, end: Double, rects: [CGRect], erase: Bool }
    private enum UndoItem { case edit(Snap), exported(URL) }
    private var undoStack: [UndoItem] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "片段截取 · 原画质"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 540)
        window.delegate = self
        window.center()
        buildUI()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.window.isKeyWindow else { return e }
            let editing = self.window.firstResponder is NSTextView
            let key = e.charactersIgnoringModifiers?.lowercased()
            if e.modifierFlags.contains(.command) && key == "z" && !editing { self.undo(); return nil }
            guard self.hasVideo, !editing, !e.modifierFlags.contains(.command) else { return e }
            switch key {
            case "i": self.markStart(); return nil
            case "o": self.markEnd(); return nil
            case " ": self.togglePlay(); return nil
            default: return e
            }
        }
    }

    private var hasVideo: Bool { source != nil || remote != nil }

    // MARK: 界面

    private func buildUI() {
        let root = DropContainer()
        root.registerForDraggedTypes([.fileURL])
        root.onDrop = { [weak self] u in self?.open(u) }
        window.contentView = root

        linkField.placeholderString = "粘贴视频链接回车：在线预览，不用整个下载；也可以把本地视频拖进窗口"
        linkField.target = self; linkField.action = #selector(loadFromField)
        let load = NSButton(title: "载入", target: self, action: #selector(loadFromField))
        let openBtn = NSButton(title: "打开本地视频…", target: self, action: #selector(openFile))
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
        marquee.videoBounds = { [weak self] in
            guard let self = self else { return .zero }
            return self.playerView.convert(self.playerView.videoBounds, to: self.marquee)
        }
        marquee.onAdd = { [weak self] f in
            guard let self = self else { return }
            self.pushEdit()
            self.marquee.fracRects.append(f)
            self.eraseCheck.state = .on
            self.refresh()
        }
        stage.addSubview(marquee)
        hint.stringValue = "看到好看的动效，只想要其中几秒？\n\n1. 上面粘贴视频链接回车 —— 在线预览，不会下载整个视频\n2. 播放到开始的地方按「设为起点」（键盘 I），到结束的地方按「设为终点」（O）\n3. 有水印点「自动找水印」，或「框选水印」自己框\n4. 点「导出片段」—— 只下载这几秒，原画质，水印同时抹掉\n\n点错了随时按「撤销」（⌘Z），导出的文件也能撤销"
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
        undoButton.bezelStyle = .rounded
        undoButton.target = self; undoButton.action = #selector(undoClicked)
        undoButton.toolTip = "撤销上一步（⌘Z）：起止点、水印框，或者把刚导出的片段删掉"
        let row1 = NSStackView(views: [button("设为起点 (I)", #selector(markStart)), startField,
                                       button("设为终点 (O)", #selector(markEnd)), endField, lengthLabel, flex(),
                                       button("▶︎ 播放这一段", #selector(playRange)), undoButton])

        eraseCheck.target = self; eraseCheck.action = #selector(eraseToggled)
        audioCheck.state = .on
        let row2 = NSStackView(views: [button("自动找水印", #selector(autoDetect)), button("框选水印", #selector(beginMarquee)),
                                       button("清除框", #selector(clearMarquee)), eraseCheck, flex(), audioCheck])

        format.addItems(withTitles: ["精确到帧 · 接近无损（H.264 MP4，推荐）",
                                     "原画质无损 · 极快（直接拷贝，起点对齐到最近的关键帧）",
                                     "ProRes 422 HQ（MOV，剪辑软件最流畅，体积大）"])
        format.selectItem(at: UserDefaults.standard.integer(forKey: "clipFormat"))
        format.target = self; format.action = #selector(optionsChanged)
        exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"
        exportButton.target = self; exportButton.action = #selector(exportClip)
        folderButton.bezelStyle = .rounded
        folderButton.target = self; folderButton.action = #selector(changeFolder)
        folderButton.lineBreakMode = .byTruncatingMiddle
        folderButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderButton.toolTip = "点一下换片段的保存位置"
        updateFolderButton()
        let row3 = NSStackView(views: [format, flex(), folderButton, button("打开", #selector(openFolder)), exportButton])

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

    private func resetForNewVideo() {
        stopPlayback()
        hint.isHidden = true
        marquee.fracRects = []
        eraseCheck.state = .off
        undoStack.removeAll { if case .edit = $0 { return true } else { return false } }
    }

    /// 本地视频
    func open(_ url: URL) {
        show()
        resetForNewVideo()
        source = url
        remote = nil
        status.stringValue = "正在读取：\(url.lastPathComponent)"
        let asset = AVURLAsset(url: url)
        playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        Task { @MainActor in
            let d = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            let size = await ClipEditor.displaySize(asset)
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

    /// 在线视频：只拿播放地址预览，不下载
    func openRemote(_ link: URL) {
        show()
        resetForNewVideo()
        source = nil
        remote = nil
        playerView.player = nil
        status.stringValue = "正在读取在线视频（不会下载整个视频）…"
        bar.isIndeterminate = true; bar.isHidden = false; bar.startAnimation(nil)
        Task { @MainActor in
            do {
                let r = try await RemoteVideo.fetch(link)
                // 分段格式（B站、YouTube）→ 拼成 HLS 预览；普通 MP4（抖音）→ 直接播
                var asset: AVURLAsset
                if !r.previewCodec.isEmpty, let (a, loader) = await PlaylistLoader.makeAsset(
                    video: HLSPreview.Track(url: r.preview, codec: r.previewCodec), audio: r.audio, headers: r.headers) {
                    asset = a
                    self.playlistLoader = loader
                } else {
                    asset = AVURLAsset(url: r.preview, options: ["AVURLAssetHTTPHeaderFieldsKey": r.headers])
                }
                self.playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                let d = r.duration > 0 ? r.duration : ((try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0)
                // 抖音直接用原文件，分辨率就是预览的分辨率
                let full = r.width > 0 ? CGSize(width: r.width, height: r.height) : await ClipEditor.displaySize(asset)
                self.remote = r
                self.duration = d
                self.videoSize = full
                self.startT = 0
                self.endT = d
                self.bar.stopAnimation(nil); self.bar.isHidden = true; self.bar.isIndeterminate = false
                self.status.stringValue = "在线预览：\(r.title) · 原画质 \(Int(full.width))×\(Int(full.height)) · \(ClipEditor.fmt(d))　（导出时只下载选中的这一段）"
                self.refresh()
            } catch {
                self.bar.stopAnimation(nil); self.bar.isHidden = true; self.bar.isIndeterminate = false
                self.status.stringValue = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    static func displaySize(_ asset: AVAsset) async -> CGSize {
        guard let t = try? await asset.loadTracks(withMediaType: .video).first,
              let (ns, tf) = try? await t.load(.naturalSize, .preferredTransform) else { return .zero }
        let r = CGRect(origin: .zero, size: ns).applying(tf)
        return CGSize(width: abs(r.width), height: abs(r.height))
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
        openRemote(u)
    }

    // MARK: 撤销

    private func snap() -> Snap { Snap(start: startT, end: endT, rects: marquee.fracRects, erase: eraseCheck.state == .on) }

    /// 每次改动之前记一下，方便撤销
    private func pushEdit() {
        undoStack.append(.edit(snap()))
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    @objc private func undoClicked() { undo() }

    func undo() {
        guard let last = undoStack.popLast() else { NSSound.beep(); return }
        switch last {
        case .edit(let s):
            startT = s.start; endT = s.end
            marquee.fracRects = s.rects
            eraseCheck.state = s.erase ? .on : .off
            status.stringValue = "已撤销"
        case .exported(let u):
            if FileManager.default.fileExists(atPath: u.path) {
                try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                status.stringValue = "已撤销导出：「\(u.lastPathComponent)」放进了废纸篓"
            } else {
                status.stringValue = "刚导出的文件已经不在了"
            }
        }
        refresh()
    }

    // MARK: 起止点

    private var currentTime: Double { playerView.player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0 }

    @objc private func markStart() {
        pushEdit()
        startT = min(max(0, currentTime), duration)
        if endT <= startT { endT = duration }
        refresh()
    }

    @objc private func markEnd() {
        pushEdit()
        endT = min(max(0, currentTime), duration)
        if endT <= startT { startT = 0 }
        refresh()
    }

    @objc private func timesEdited() {
        let s = ClipEditor.parse(startField.stringValue), e = ClipEditor.parse(endField.stringValue)
        guard s != nil && abs(s! - startT) > 0.001 || e != nil && abs(e! - endT) > 0.001 else { refresh(); return }
        pushEdit()
        if let s = s { startT = min(max(0, s), duration) }
        if let e = e { endT = min(max(0, e), duration) }
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
            DispatchQueue.main.async {
                self.boundaryObserver = p.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: self.endT, preferredTimescale: 600))],
                                                                  queue: .main) { [weak self] in self?.stopPlayback() }
                p.play()
            }
        }
    }

    private func stopPlayback() {
        playerView.player?.pause()
        if let o = boundaryObserver { playerView.player?.removeTimeObserver(o); boundaryObserver = nil }
    }

    // MARK: 水印

    @objc private func beginMarquee() {
        guard hasVideo else { return }
        playerView.player?.pause()
        marquee.selecting = true
    }

    @objc private func clearMarquee() {
        guard !marquee.fracRects.isEmpty else { return }
        pushEdit()
        marquee.fracRects = []
        eraseCheck.state = .off
        refresh()
    }

    @objc private func eraseToggled() {
        undoStack.append(.edit(Snap(start: startT, end: endT, rects: marquee.fracRects, erase: eraseCheck.state != .on)))
        refresh()
    }

    /// 在整个视频里取十几帧，找角落里一直不动的标志
    @objc private func autoDetect() {
        guard hasVideo, duration > 1 else { return }
        status.stringValue = "正在找水印…"
        let remote = self.remote, dur = duration, source = self.source
        Task { @MainActor in
            var frames: [CGImage] = []
            if let r = remote {
                frames = await Watermark.sampleFrames(url: r.direct ?? r.preview, headers: r.headers, duration: dur)
            } else if let s = source {
                frames = await Watermark.sampleFrames(AVURLAsset(url: s), duration: dur)
                if frames.count < 4 { frames = await Watermark.sampleFrames(url: s, headers: [:], duration: dur) }
            }
            let rects = await Task.detached { Watermark.detect(frames: frames) }.value
            if rects.isEmpty {
                self.status.stringValue = "没找到固定位置的水印。如果有，用「框选水印」自己框一下"
                return
            }
            self.pushEdit()
            self.marquee.fracRects = rects
            self.eraseCheck.state = .on
            self.status.stringValue = "找到 \(rects.count) 处水印（红框）。不对的话点「清除框」再自己框"
            self.refresh()
        }
    }

    @objc private func optionsChanged() {
        UserDefaults.standard.set(format.indexOfSelectedItem, forKey: "clipFormat")
        refresh()
    }

    private func refresh() {
        startField.stringValue = ClipEditor.fmt(startT)
        endField.stringValue = ClipEditor.fmt(endT)
        lengthLabel.stringValue = hasVideo ? String(format: "共 %.2f 秒", max(0, endT - startT)) : ""
        eraseCheck.isEnabled = !marquee.fracRects.isEmpty
        exportButton.isEnabled = hasVideo && endT > startT && exporting == nil
        undoButton.isEnabled = !undoStack.isEmpty
        if case .exported? = undoStack.last { undoButton.title = "↶ 撤销导出" } else { undoButton.title = "↶ 撤销" }
        if eraseCheck.state == .on && !marquee.fracRects.isEmpty && format.indexOfSelectedItem == 1 {
            status.stringValue = "抹水印需要重新编码：会自动改用「精确到帧 · 接近无损」"
        }
    }

    // MARK: 保存位置

    @objc private func openFolder() { NSWorkspace.shared.open(ClipEditor.folder) }

    @objc private func changeFolder() {
        DownloaderController.chooseFolder(key: "clipFolder", current: ClipEditor.folder, in: window) { [weak self] _ in
            self?.updateFolderButton()
        }
    }

    private func updateFolderButton() {
        folderButton.title = "存到：\(DownloaderController.shortPath(ClipEditor.folder)) ▾"
    }

    // MARK: 导出

    /// ffmpeg 的编码参数（不含输入输出）
    private func encodeArgs(mode: Int, filter: String?) -> [String] {
        var a: [String] = []
        let audio = audioCheck.state == .on
        switch mode {
        case 1:
            a += ["-c", "copy"]
        case 2:
            if let f = filter { a += ["-vf", f] }
            a += ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-vendor", "apl0"]
            if audio { a += ["-c:a", "pcm_s16le"] }
        default:
            if let f = filter { a += ["-vf", f] }
            a += ["-c:v", "libx264", "-crf", "12", "-preset", "slow", "-pix_fmt", "yuv420p", "-tag:v", "avc1"]
            if audio { a += ["-c:a", "aac", "-b:a", "320k"] }
        }
        if !audio { a += ["-an"] }
        return a
    }

    @objc private func exportClip() {
        guard hasVideo, endT > startT, exporting == nil else { return }
        guard let ffmpeg = Tools.ffmpeg else {
            status.stringValue = "需要 ffmpeg 才能截取（可以用 Homebrew 安装：brew install ffmpeg）"; return
        }
        stopPlayback()
        let rects = eraseCheck.state == .on ? marquee.fracRects : []
        let filter = rects.isEmpty ? nil : Watermark.delogoFilter(rects, width: Int(videoSize.width), height: Int(videoSize.height))
        var mode = format.indexOfSelectedItem
        if mode == 1 && filter != nil { mode = 0 }
        let dur = endT - startT

        let rawName = remote?.title ?? source?.deletingPathExtension().lastPathComponent ?? "片段"
        let base = DownloaderController.safeName(rawName.replacingOccurrences(of: #"\s*\[[^\]]+\]$"#, with: "", options: .regularExpression))
        let tag = "\(ClipEditor.fmt(startT))-\(ClipEditor.fmt(endT))".replacingOccurrences(of: ":", with: ".")
        let ext = mode == 2 ? "mov" : (mode == 1 && source != nil ? (source!.pathExtension.isEmpty ? "mp4" : source!.pathExtension) : "mp4")
        let folder = ClipEditor.folder
        var out = folder.appendingPathComponent("\(base) 片段 \(tag).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = folder.appendingPathComponent("\(base) 片段 \(tag) (\(n)).\(ext)"); n += 1
        }

        let p = Process()
        var indeterminate = false
        if let r = remote, r.direct == nil {
            // 在线视频（B站、YouTube…）：yt-dlp 只下载这一段，下载时就用 ffmpeg 编码、抹水印，只出一个文件
            guard let ytdlp = Tools.ytdlp else { status.stringValue = "没有下载组件 yt-dlp"; return }
            p.executableURL = URL(fileURLWithPath: ytdlp)
            var args = [r.page.absoluteString, "--no-playlist", "--no-warnings", "--no-part",
                        "-S", "res,fps,vcodec:h264,acodec:aac",
                        "--download-sections", String(format: "*%.3f-%.3f", startT, endT),
                        "--downloader", "ffmpeg",
                        "-o", out.deletingPathExtension().path + ".%(ext)s",
                        "--merge-output-format", ext] + Tools.commonArgs()
            if !(audioCheck.state == .on) { args += ["-f", "bv*"] }
            if mode != 1 || audioCheck.state != .on {
                args += ["--downloader-args", "ffmpeg_o:" + encodeArgs(mode: mode, filter: filter).joined(separator: " ")]
            }
            p.arguments = args
            p.environment = Tools.env
            indeterminate = true
        } else {
            // 本地文件，或抖音的原文件地址：ffmpeg 直接从起点读到终点
            var args = ["-hide_banner", "-nostdin", "-y"]
            args += ["-ss", String(format: "%.3f", startT)]
            if let r = remote, let d = r.direct {
                args += ["-user_agent", Douyin.mobileUA, "-headers", "Referer: https://www.douyin.com/\r\n", "-i", d.absoluteString]
            } else if let s = source {
                args += ["-i", s.path]
            }
            args += ["-t", String(format: "%.3f", dur), "-map", "0:v:0"]
            if audioCheck.state == .on { args += ["-map", "0:a:0?"] }
            args += encodeArgs(mode: mode, filter: filter)
            if mode == 1 { args += ["-avoid_negative_ts", "make_zero"] }
            if mode != 2 { args += ["-movflags", "+faststart"] }
            args += ["-progress", "pipe:1", "-nostats", out.path]
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = args
        }

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
            errTail = String((errTail + String(decoding: d, as: UTF8.self)).suffix(600))
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.exporting = nil
                self.bar.stopAnimation(nil)
                self.bar.isHidden = true
                self.bar.isIndeterminate = false
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                    self.undoStack.append(.exported(out))
                    self.status.stringValue = "✅ 已导出：\(out.lastPathComponent)（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）　点错了可以按「撤销导出」"
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                } else {
                    let last = errTail.split(separator: "\n").last { $0.contains("ERROR") || $0.contains("rror") }
                        ?? errTail.split(separator: "\n").last
                    self.status.stringValue = "导出失败：\(last.map(String.init) ?? "未知原因")"
                }
                self.refresh()
            }
        }
        do {
            try p.run()
            exporting = p
            bar.isIndeterminate = indeterminate
            bar.doubleValue = 0
            bar.isHidden = false
            if indeterminate { bar.startAnimation(nil) }
            let what = remote != nil ? "正在下载这一段并导出" : (mode == 1 ? "正在拷贝原画质片段" : "正在高画质导出")
            status.stringValue = "\(what)\(filter != nil ? "（同时抹掉水印）" : "")…"
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
