// 视频下载：粘贴抖音 / B站 / YouTube / 小红书 / TikTok / 微博 等链接，下载无水印原画质
// 抖音走分享页拿无水印地址；其他网站交给 yt-dlp（本机已装的或自动下载的）
import Cocoa

// MARK: - 下载组件（yt-dlp / ffmpeg）

enum Tools {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("桌面翻译器/tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func find(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [dir.appendingPathComponent(name).path, "\(home)/.local/bin/\(name)",
                          "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ytdlp: String? { find("yt-dlp") ?? find("yt-dlp_macos") }

    /// 每次调用 yt-dlp 都带上：代理、JS 运行环境、重试、浏览器登录状态
    static func commonArgs() -> [String] {
        var a = ["--retries", "10", "--fragment-retries", "10", "--extractor-retries", "5", "--socket-timeout", "20"]
        if let js = jsRuntime { a += ["--js-runtimes", js] }
        if let px = systemProxy { a += ["--proxy", px] }
        if let ff = ffmpeg { a += ["--ffmpeg-location", ff] }
        let browsers = ["", "safari", "chrome", "edge", "firefox"]
        let bi = UserDefaults.standard.integer(forKey: "dlCookies")
        if bi > 0 && bi < browsers.count { a += ["--cookies-from-browser", browsers[bi]] }
        return a
    }

    /// YouTube 要靠 JS 运行环境算出下载参数，没有它会被限速、缺画质
    static var jsRuntime: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let d = find("deno") ?? ["\(home)/.deno/bin/deno"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return "deno:\(d)"
        }
        let nodes = [dir.appendingPathComponent("node").path, "/opt/homebrew/bin/node", "/usr/local/bin/node",
                     "\(home)/.local/bin/node", "\(home)/Documents/Codex/tools/node/bin/node", "\(home)/.volta/bin/node"]
        if let n = nodes.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return "node:\(n)" }
        let nvm = "\(home)/.nvm/versions/node"
        if let v = (try? FileManager.default.contentsOfDirectory(atPath: nvm))?.sorted().last,
           FileManager.default.isExecutableFile(atPath: "\(nvm)/\(v)/bin/node") { return "node:\(nvm)/\(v)/bin/node" }
        return nil
    }

    /// 系统设置里的代理（Clash 等）。从「应用程序」启动的进程拿不到终端里的代理变量，要自己读出来交给 yt-dlp，否则直连会非常慢
    static var systemProxy: String? {
        guard let d = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        func pick(_ en: String, _ host: String, _ port: String, _ scheme: String) -> String? {
            guard (d[en] as? Int) == 1, let h = d[host] as? String, !h.isEmpty else { return nil }
            let p = (d[port] as? Int).map { ":\($0)" } ?? ""
            return "\(scheme)://\(h)\(p)"
        }
        return pick("HTTPSEnable", "HTTPSProxy", "HTTPSPort", "http")
            ?? pick("HTTPEnable", "HTTPProxy", "HTTPPort", "http")
            ?? pick("SOCKSEnable", "SOCKSProxy", "SOCKSPort", "socks5")
    }
    static var ffmpeg: String? { find("ffmpeg") }

    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        e["PATH"] = "\(dir.path):\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (e["PATH"] ?? "")
        e["PYTHONIOENCODING"] = "utf-8"
        e["LANG"] = "zh_CN.UTF-8"
        if let p = systemProxy {
            for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"] { e[k] = p }
            e["NO_PROXY"] = "localhost,127.0.0.1"
        }
        return e
    }

    /// 没装 yt-dlp 时，从官方 GitHub 下载独立版
    static func installYtdlp(completion: @escaping (Bool) -> Void) {
        let src = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        URLSession.shared.downloadTask(with: src) { tmp, resp, _ in
            var ok = false
            if let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200 {
                let dst = dir.appendingPathComponent("yt-dlp")
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil {
                    chmod(dst.path, 0o755)
                    ok = true
                }
            }
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    /// 更新 yt-dlp：独立版用自带的 -U；pip 装的用它自己的 python 升级
    static func updateCommand() -> (String, [String])? {
        guard let y = ytdlp else { return nil }
        if let head = try? String(contentsOfFile: y, encoding: .utf8).prefix(300),
           head.hasPrefix("#!"), let line = head.split(separator: "\n").first, line.contains("python") {
            let py = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return (py, ["-m", "pip", "install", "-U", "yt-dlp"])
        }
        return (y, ["-U"])
    }
}

// MARK: - 链接识别

enum LinkParser {
    /// 从分享文字里抠出第一个网址（抖音、小红书的分享文字里夹着链接）
    static func firstURL(in text: String) -> URL? {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ms = det.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in ms {
            if let u = m.url, let s = u.scheme?.lowercased(), s == "http" || s == "https" { return u }
        }
        return nil
    }

    static func isDouyin(_ u: URL) -> Bool {
        let h = u.host?.lowercased() ?? ""
        return h.hasSuffix("douyin.com") || h.hasSuffix("iesdouyin.com")
    }

    static func siteName(_ u: URL) -> String {
        let h = u.host?.lowercased() ?? ""
        let table: [(String, String)] = [("douyin", "抖音"), ("bilibili", "B站"), ("b23.tv", "B站"), ("youtu", "YouTube"),
                                         ("xiaohongshu", "小红书"), ("xhslink", "小红书"), ("tiktok", "TikTok"),
                                         ("weibo", "微博"), ("twitter", "X"), ("x.com", "X"), ("instagram", "Instagram"),
                                         ("vimeo", "Vimeo"), ("ixigua", "西瓜视频")]
        return table.first { h.contains($0.0) }?.1 ?? (u.host ?? "网页")
    }
}

// MARK: - 抖音无水印

enum Douyin {
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    struct Item { let title: String; let videoURLs: [URL]; let images: [URL] }

    static func resolve(_ link: URL) async throws -> Item {
        var r = URLRequest(url: link)
        r.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 10
        // 短链接会跳转到带作品 ID 的地址
        let (_, resp) = try await URLSession.shared.data(for: r)
        let final = resp.url?.absoluteString ?? link.absoluteString
        guard let id = match(final, "(?:video|note|slides)/(\\d{15,})") ?? match(final, "(?:modal_id|vid|aweme_id)=(\\d{15,})")
                ?? match(link.absoluteString, "(\\d{17,})") else {
            throw TError(message: "没找到抖音作品编号")
        }
        var r2 = URLRequest(url: URL(string: "https://www.iesdouyin.com/share/video/\(id)/")!)
        r2.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        r2.timeoutInterval = 10
        let (d, _) = try await URLSession.shared.data(for: r2)
        let html = String(decoding: d, as: UTF8.self)
        guard let jsonText = match(html, "window\\._ROUTER_DATA\\s*=\\s*(\\{.*?\\})\\s*</script>"),
              let root = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
              let loader = root["loaderData"] as? [String: Any] else {
            throw TError(message: "抖音页面结构变了，读不到作品信息")
        }
        var item: [String: Any]?
        for (_, v) in loader {
            if let page = v as? [String: Any], let info = page["videoInfoRes"] as? [String: Any],
               let list = info["item_list"] as? [[String: Any]], let first = list.first { item = first; break }
        }
        guard let it = item else { throw TError(message: "作品不存在、已删除或仅自己可见") }
        let title = (it["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "抖音_\(id)"

        // 图文作品
        if let imgs = it["images"] as? [[String: Any]], !imgs.isEmpty {
            let urls = imgs.compactMap { ($0["url_list"] as? [String])?.first.flatMap(URL.init(string:)) }
            return Item(title: title, videoURLs: [], images: urls)
        }
        guard let video = it["video"] as? [String: Any] else { throw TError(message: "这个作品里没有视频") }
        var cands: [URL] = []
        // 多个码率里挑最高的
        if let rates = video["bit_rate"] as? [[String: Any]] {
            let sorted = rates.sorted { ($0["bit_rate"] as? Int ?? 0) > ($1["bit_rate"] as? Int ?? 0) }
            for b in sorted {
                if let pa = b["play_addr"] as? [String: Any], let l = pa["url_list"] as? [String] {
                    cands += l.compactMap { URL(string: $0.replacingOccurrences(of: "playwm", with: "play")) }
                }
            }
        }
        if let pa = video["play_addr"] as? [String: Any] {
            if let uri = pa["uri"] as? String, !uri.isEmpty {
                for ratio in ["1080p", "720p"] {
                    if let u = URL(string: "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(uri)&ratio=\(ratio)&line=0") { cands.append(u) }
                }
            }
            if let l = pa["url_list"] as? [String] {
                cands += l.compactMap { URL(string: $0.replacingOccurrences(of: "playwm", with: "play")) }
            }
        }
        guard !cands.isEmpty else { throw TError(message: "没拿到视频地址") }
        return Item(title: title, videoURLs: cands, images: [])
    }

    static func match(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let rg = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[rg])
    }
}

// MARK: - 直接下载（带进度）

final class DirectDownload: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private let dest: URL
    private let onProgress: (Double, Double) -> Void          // 进度 0~1，速度 字节/秒
    private let onDone: (Result<URL, Error>) -> Void
    private var started = Date()
    private var task: URLSessionDownloadTask?

    init(_ req: URLRequest, to dest: URL, progress: @escaping (Double, Double) -> Void, done: @escaping (Result<URL, Error>) -> Void) {
        self.dest = dest; onProgress = progress; onDone = done
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session.downloadTask(with: req)
        task?.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        let speed = Double(w) / max(0.1, Date().timeIntervalSince(started))
        onProgress(t > 0 ? Double(w) / Double(t) : 0, speed)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let type = (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard code == 200, !type.contains("text/html"), !type.contains("json") else {
            onDone(.failure(TError(message: "服务器返回 \(code)"))); s.finishTasksAndInvalidate(); return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            onDone(.success(dest))
        } catch { onDone(.failure(error)) }
        s.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { onDone(.failure(e)); s.finishTasksAndInvalidate() }
    }
}

// MARK: - 一条下载任务

final class DownloadJob {
    enum State { case running, done, failed, cancelled, deleting, deleted }
    let link: URL
    var title: String
    var state = State.running
    var progress: Double = 0
    var detail = "准备中…"
    var files: [URL] = []
    var trashedFiles: [URL] = []
    var process: Process?
    var direct: DirectDownload?
    var onChange: (() -> Void)?
    var onFinished: ((URL) -> Void)?

    init(link: URL) { self.link = link; title = "\(LinkParser.siteName(link))：\(link.absoluteString)" }

    func update(_ f: () -> Void) { f(); onChange?() }

    func cancel() {
        guard state == .running else { return }
        process?.terminate()
        direct?.cancel()
        update { state = .cancelled; detail = "已取消" }
    }

    func deleteLocalFiles() {
        guard state == .done, !files.isEmpty else { return }
        let targets = files
        update { state = .deleting; detail = "正在移到废纸篓…" }
        DispatchQueue.global(qos: .utility).async {
            let report = DownloadFileTrash.move(targets)
            DispatchQueue.main.async {
                self.update {
                    self.files = report.remaining
                    self.trashedFiles += report.trashed
                    self.state = report.remaining.isEmpty ? .deleted : .done
                    var parts: [String] = []
                    if !report.trashed.isEmpty { parts.append("已移到废纸篓（\(report.trashed.count) 个文件），可在废纸篓恢复") }
                    if report.missing > 0 { parts.append("\(report.missing) 个本地文件已不存在") }
                    if !report.errors.isEmpty { parts.append("\(report.remaining.count) 个文件未删除：\(report.errors.joined(separator: "；"))") }
                    self.detail = parts.joined(separator: " · ")
                }
            }
        }
    }
}

final class JobRow: NSView {
    let job: DownloadJob
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let button = NSButton(title: "取消", target: nil, action: nil)
    private let clipButton = NSButton(title: "截片段 / 去水印", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    var onClip: ((URL) -> Void)?

    init(job: DownloadJob) {
        self.job = job
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.controlSize = .small
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(buttonClicked)
        clipButton.bezelStyle = .rounded
        clipButton.controlSize = .small
        clipButton.target = self
        clipButton.action = #selector(clipClicked)
        clipButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.identifier = NSUserInterfaceItemIdentifier("download.delete-local")
        deleteButton.toolTip = "将这条下载对应的本地文件移到废纸篓，可恢复"
        for action in [clipButton, deleteButton, button] {
            action.setContentHuggingPriority(.required, for: .horizontal)
            action.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let text = NSStackView(views: [titleLabel, bar, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [text, clipButton, deleteButton, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
        ])
        button.setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        titleLabel.stringValue = job.title
        detailLabel.stringValue = job.detail
        detailLabel.toolTip = job.detail
        detailLabel.textColor = job.state == .failed ? .systemRed : .secondaryLabelColor
        bar.doubleValue = job.state == .done ? 1 : job.progress
        bar.isHidden = job.state == .failed || job.state == .cancelled || job.state == .deleted
        clipButton.isHidden = !(job.state == .done && job.files.contains { ClipEditor.isVideo($0) })
        deleteButton.isHidden = !((job.state == .done || job.state == .deleting) && !job.files.isEmpty)
        deleteButton.isEnabled = job.state == .done
        deleteButton.title = job.state == .deleting ? "删除中…" : "删除"
        button.isEnabled = job.state != .deleting && (job.state != .deleted || !job.trashedFiles.isEmpty)
        switch job.state {
        case .running: button.title = "取消"
        case .done: button.title = "在访达中显示"
        case .deleting: button.title = "在访达中显示"
        case .deleted: button.title = job.trashedFiles.isEmpty ? "文件已不存在" : "查看废纸篓"
        case .failed, .cancelled: button.title = "重试"
        }
        ProductTheme.styleButton(button)
        ProductTheme.styleButton(clipButton)
        ProductTheme.styleButton(deleteButton)
    }

    var onRetry: ((DownloadJob) -> Void)?

    @objc private func clipClicked() {
        if let f = job.files.last(where: { ClipEditor.isVideo($0) }) { onClip?(f) }
    }

    @objc private func deleteClicked() { job.deleteLocalFiles() }

    @objc private func buttonClicked() {
        switch job.state {
        case .running: job.cancel()
        case .done:
            if job.files.isEmpty { NSWorkspace.shared.open(DownloaderController.folder) }
            else { NSWorkspace.shared.activateFileViewerSelecting(job.files) }
        case .deleting: break
        case .deleted:
            if !job.trashedFiles.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(job.trashedFiles) }
        case .failed, .cancelled: onRetry?(job)
        }
    }
}

// MARK: - 下载窗口

final class DownloaderController: NSObject, NSWindowDelegate {
    static let defaultFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("截图翻译视频下载", isDirectory: true)

    /// 保存位置：用户自己选的文件夹，没选过就用「下载/截图翻译视频下载」
    static var folder: URL {
        let d = UserDefaults.standard.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 弹出选择文件夹；选好返回路径
    static func chooseFolder(key: String, current: URL, in window: NSWindow?, done: @escaping (URL) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "存到这里"
        p.message = "选择保存位置"
        p.directoryURL = current
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK, let u = p.url else { return }
            UserDefaults.standard.set(u.path, forKey: key)
            done(u)
        }
        if let w = window { p.beginSheetModal(for: w, completionHandler: handle) } else { handle(p.runModal()) }
    }

    static func shortPath(_ u: URL) -> String {
        u.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    let window: NSWindow
    private let field = NSTextField()
    private let quality = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cookies = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoWM = NSButton(checkboxWithTitle: "自动去水印", target: nil, action: nil)
    private let folderButton = NSButton(title: "", target: nil, action: nil)
    private let list = NSStackView()
    private let footer = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(wrappingLabelWithString: "")
    private var jobs: [DownloadJob] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "视频下载"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 480)
        window.delegate = self
        window.center()
        buildUI()
        restoreHistory()
        ProductTheme.apply(to: window)
    }

    private func buildUI() {
        let content = window.contentView!
        let header = ProductTheme.header("03 / 视频下载", "把灵感，存到手边。", "粘贴作品链接，选择画质和保存位置。")

        field.placeholderString = "粘贴抖音 / B站 / YouTube / 小红书 / TikTok 的链接或分享文字，按回车"
        field.font = .systemFont(ofSize: 14)
        field.target = self
        field.action = #selector(startFromField)
        let go = NSButton(title: "下载", target: self, action: #selector(startFromField))
        ProductTheme.primary(go)
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"
        let paste = NSButton(title: "粘贴并下载", target: self, action: #selector(pasteAndStart))
        paste.bezelStyle = .rounded

        quality.addItems(withTitles: ["原画质（最高）", "1080p 以内", "只要声音（MP3）"])
        quality.selectItem(at: UserDefaults.standard.integer(forKey: "dlQuality"))
        quality.target = self; quality.action = #selector(saveOptions)
        cookies.addItems(withTitles: ["不用浏览器登录", "用 Safari 的登录", "用 Chrome 的登录", "用 Edge 的登录", "用 Firefox 的登录"])
        cookies.selectItem(at: UserDefaults.standard.integer(forKey: "dlCookies"))
        cookies.target = self; cookies.action = #selector(saveOptions)
        cookies.toolTip = "B站 4K / 大会员画质、需要登录才能看的视频，选你平时登录这个网站的浏览器"
        let open = NSButton(title: "打开", target: self, action: #selector(openFolder))
        open.bezelStyle = .rounded
        folderButton.bezelStyle = .rounded
        folderButton.target = self
        folderButton.action = #selector(changeFolder)
        folderButton.lineBreakMode = .byTruncatingMiddle
        folderButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderButton.toolTip = "点一下换保存位置"
        updateFolderButton()
        autoWM.state = UserDefaults.standard.object(forKey: "autoWatermark") as? Bool ?? true ? .on : .off
        autoWM.target = self; autoWM.action = #selector(saveOptions)
        autoWM.toolTip = "下载完自动找画面角落里一直不动的水印（比如 B站 UP 主水印）并抹掉，直接替换原文件，不会多占一份空间。没找到水印就不动原视频。"
        for c in [quality, cookies] { c.controlSize = .regular }

        let row1 = NSStackView(views: [field, paste, go])
        row1.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let flex = NSView()
        flex.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row2 = NSStackView(views: [quality, cookies, autoWM, flex])
        row2.spacing = 8
        let folderFlex = NSView()
        folderFlex.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let folderRow = NSStackView(views: [folderButton, open, folderFlex])
        folderRow.spacing = 8
        folderButton.widthAnchor.constraint(lessThanOrEqualToConstant: 540).isActive = true

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        emptyHint.stringValue = "还没有下载任务。\n\n把作品的分享链接粘进来，选好保存位置再下载。\n支持抖音、B站、YouTube、小红书等，具体支持随网站变化。\n\n只想要其中几秒？打开「片段截取」，预览后选择起止点。\n去水印采用周围画面填平，复杂背景可能留痕。"
        emptyHint.textColor = .secondaryLabelColor
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(emptyHint)
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .bezelBorder
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
            emptyHint.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 16),
            emptyHint.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -16),
            emptyHint.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
        ])

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let update = NSButton(title: "更新下载组件", target: self, action: #selector(updateTools))
        update.bezelStyle = .rounded
        update.controlSize = .small
        let flex2 = NSView()
        flex2.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row3 = NSStackView(views: [footer, flex2, update])

        let stack = NSStackView(views: [header, row1, row2, scroll, folderRow, row3])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [header, row1, row2, scroll, folderRow, row3] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualTo: content.heightAnchor, multiplier: 0.0, constant: 140).isActive = true
        refreshFooter()
    }

    private func refreshFooter() {
        let y = Tools.ytdlp != nil ? "yt-dlp ✓" : "yt-dlp 未安装（第一次下载非抖音链接时会自动安装）"
        let f = Tools.ffmpeg != nil ? "ffmpeg ✓" : "ffmpeg 未安装（只能下载不需要合成的格式）"
        let j = Tools.jsRuntime != nil ? "YouTube 加速 ✓" : "YouTube 加速未开启（可装 deno 或 Node.js）"
        let px = Tools.systemProxy.map { "代理 \($0.replacingOccurrences(of: "http://", with: ""))" } ?? "直连"
        footer.toolTip = "\(y)　·　\(f)　·　\(j)　·　\(px)"
        footer.stringValue = Tools.ytdlp != nil && Tools.ffmpeg != nil ? "下载与片段组件已就绪" : "首次使用请检查下载组件"
    }

    // MARK: 打开

    func show(link: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let l = link, let u = LinkParser.firstURL(in: l) { start(u); return }
        // 剪贴板里有链接就先填上
        if field.stringValue.isEmpty, let s = NSPasteboard.general.string(forType: .string), LinkParser.firstURL(in: s) != nil {
            field.stringValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
            field.currentEditor()?.selectAll(nil)
        }
        window.makeFirstResponder(field)
    }

    @objc private func saveOptions() {
        UserDefaults.standard.set(quality.indexOfSelectedItem, forKey: "dlQuality")
        UserDefaults.standard.set(cookies.indexOfSelectedItem, forKey: "dlCookies")
        UserDefaults.standard.set(autoWM.state == .on, forKey: "autoWatermark")
    }

    @objc private func openFolder() { NSWorkspace.shared.open(DownloaderController.folder) }

    @objc private func changeFolder() {
        DownloaderController.chooseFolder(key: "saveFolder", current: DownloaderController.folder, in: window) { [weak self] _ in
            self?.updateFolderButton(); self?.refreshFooter()
        }
    }

    private func updateFolderButton() {
        folderButton.title = "存到：\(DownloaderController.shortPath(DownloaderController.folder)) ▾"
        ProductTheme.styleButton(folderButton)
    }

    /// 下载完成：需要的话先自动去水印，再标记完成
    private func finish(_ job: DownloadJob, file: URL?, summary: @escaping () -> String) {
        guard autoWM.state == .on, let f = file, ClipEditor.isVideo(f) else {
            job.update { job.state = .done; job.progress = 1; job.detail = summary() }
            notifyDone(job); return
        }
        WatermarkRemover.process(f, progress: { text, p in
            job.update { job.detail = text; job.progress = p }
        }, done: { [weak self] removed, err in
            job.update {
                job.state = .done; job.progress = 1
                job.detail = summary() + (removed ? " · 已自动去水印" : (err.map { " · \($0)" } ?? " · 没发现水印"))
            }
            self?.notifyDone(job)
        })
    }

    @objc private func pasteAndStart() {
        field.stringValue = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        startFromField()
    }

    @objc private func startFromField() {
        let text = field.stringValue
        guard let u = LinkParser.firstURL(in: text) else { NSSound.beep(); return }
        field.stringValue = ""
        start(u)
    }

    // MARK: 开始下载

    private func addRow(for job: DownloadJob) {
        jobs.insert(job, at: 0)
        let row = JobRow(job: job)
        row.onRetry = { [weak self, weak row] j in
            if let r = row { self?.list.removeView(r) }
            self?.jobs.removeAll { $0 === j }
            self?.start(j.link, onFinished: j.onFinished)
        }
        job.onChange = { [weak self, weak row, weak job] in
            row?.refresh()
            if let job = job, job.state == .done || job.state == .deleted { self?.saveHistory() }
        }
        row.onClip = { url in ClipEditor.shared.open(url) }
        list.insertView(row, at: 0, in: .top)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        emptyHint.isHidden = true
    }

    private func saveHistory() {
        let entries = jobs.filter { $0.state == .done || $0.state == .deleting }.map {
            DownloadHistoryEntry(link: $0.link, title: $0.title, detail: $0.detail, files: $0.files)
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "downloadHistoryV1")
        }
    }

    private func restoreHistory() {
        let entries: [DownloadHistoryEntry]
        if let data = UserDefaults.standard.data(forKey: "downloadHistoryV1") {
            guard let decoded = try? JSONDecoder().decode([DownloadHistoryEntry].self, from: data) else { return }
            entries = decoded
        } else {
            // The earlier app kept no history. Recover existing media from the save folder only,
            // without traversing subfolders or changing any file.
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
            let media = Set(["mp4", "mov", "mkv", "webm", "m4v", "avi", "mp3", "m4a", "wav", "flac", "aac", "ogg"])
            let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder,
                includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            entries = files.filter { url in
                let info = try? url.resourceValues(forKeys: keys)
                return media.contains(url.pathExtension.lowercased()) && info?.isRegularFile == true && info?.isSymbolicLink != true
            }.sorted {
                let a = try? $0.resourceValues(forKeys: keys).contentModificationDate
                let b = try? $1.resourceValues(forKeys: keys).contentModificationDate
                return (a ?? .distantPast) > (b ?? .distantPast)
            }.prefix(200).map {
                DownloadHistoryEntry(link: $0, title: $0.deletingPathExtension().lastPathComponent,
                                     detail: "本地已下载 · \($0.lastPathComponent)", files: [$0])
            }
        }
        for entry in entries.reversed() {
            let job = DownloadJob(link: entry.link)
            job.title = entry.title; job.detail = entry.detail
            job.files = entry.files; job.state = .done; job.progress = 1
            addRow(for: job)
        }
        saveHistory()
    }

    func start(_ link: URL, onFinished: ((URL) -> Void)? = nil) {
        let job = DownloadJob(link: link)
        job.onFinished = onFinished
        addRow(for: job)

        if LinkParser.isDouyin(link) {
            job.update { job.detail = "正在解析抖音作品…" }
            Task { @MainActor in
                do {
                    let item = try await Douyin.resolve(link)
                    job.update { job.title = "抖音：\(item.title)" }
                    if !item.images.isEmpty { self.downloadImages(item, job: job) }
                    else { self.downloadDirect(item.videoURLs, name: item.title, ext: "mp4", job: job) }
                } catch {
                    // 解析失败再交给 yt-dlp 试一次
                    job.update { job.detail = "抖音解析没成功（\(error.localizedDescription)），换方式再试…" }
                    self.runYtdlp(job)
                }
            }
        } else {
            runYtdlp(job)
        }
    }

    static func safeName(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        for c in "/\\:*?\"<>|#" { t = t.replacingOccurrences(of: String(c), with: " ") }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count > 60 { t = String(t.prefix(60)) }
        return t.isEmpty ? "video" : t
    }

    private func uniqueURL(_ name: String, _ ext: String) -> URL {
        var u = DownloaderController.folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = DownloaderController.folder.appendingPathComponent("\(name) (\(n)).\(ext)"); n += 1
        }
        return u
    }

    private func downloadDirect(_ cands: [URL], name: String, ext: String, job: DownloadJob) {
        guard job.state == .running else { return }
        guard let first = cands.first else {
            job.update { job.state = .failed; job.detail = "所有下载地址都失效了，稍后再试" }
            return
        }
        let dest = uniqueURL(DownloaderController.safeName(name), ext)
        var req = URLRequest(url: first)
        req.setValue(Douyin.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        job.update { job.detail = "下载中…" }
        job.direct = DirectDownload(req, to: dest, progress: { p, speed in
            job.update {
                job.progress = p
                job.detail = String(format: "%.0f%%　%@/s", p * 100, ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))
            }
        }, done: { [weak self] r in
            guard job.state == .running else { return }
            switch r {
            case .success(let u):
                let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                if size < 50_000 {   // 太小多半是错误页，换下一个地址
                    try? FileManager.default.removeItem(at: u)
                    self?.downloadDirect(Array(cands.dropFirst()), name: name, ext: ext, job: job)
                    return
                }
                job.files = [u]
                self?.finish(job, file: u) {
                    let sz = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? size
                    return "✅ 完成 · \(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file)) · \(u.lastPathComponent)"
                }
            case .failure:
                self?.downloadDirect(Array(cands.dropFirst()), name: name, ext: ext, job: job)
            }
        })
    }

    private func downloadImages(_ item: Douyin.Item, job: DownloadJob) {
        let folder = DownloaderController.folder.appendingPathComponent(DownloaderController.safeName(item.title), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = item.images.count
        job.update { job.detail = "图文作品，共 \(total) 张…" }
        Task { @MainActor in
            var saved: [URL] = []
            for (i, u) in item.images.enumerated() {
                guard job.state == .running else { return }
                var req = URLRequest(url: u)
                req.setValue(Douyin.mobileUA, forHTTPHeaderField: "User-Agent")
                if let (d, _) = try? await URLSession.shared.data(for: req), d.count > 1000 {
                    let ext = u.path.contains(".webp") || d.starts(with: [0x52, 0x49, 0x46, 0x46]) ? "webp" : "jpg"
                    let f = folder.appendingPathComponent(String(format: "%02d.%@", i + 1, ext))
                    try? d.write(to: f)
                    saved.append(f)
                }
                job.update { job.progress = Double(i + 1) / Double(total); job.detail = "图片 \(i + 1)/\(total)" }
            }
            job.update {
                job.files = saved
                job.state = saved.isEmpty ? .failed : .done
                job.detail = saved.isEmpty ? "图片都没下载成功" : "✅ 完成 · \(saved.count) 张图片 · 存在「\(folder.lastPathComponent)」文件夹"
            }
            if !saved.isEmpty { notifyDone(job) }
        }
    }

    // MARK: yt-dlp

    private func runYtdlp(_ job: DownloadJob) {
        guard let ytdlp = Tools.ytdlp else {
            job.update { job.detail = "第一次使用，正在安装下载组件 yt-dlp（约 35MB）…" }
            Tools.installYtdlp { [weak self] ok in
                self?.refreshFooter()
                if ok { self?.runYtdlp(job) }
                else { job.update { job.state = .failed; job.detail = "下载组件安装失败，请检查网络（需要能访问 GitHub）" } }
            }
            return
        }
        var args = [job.link.absoluteString,
                    "--newline", "--progress", "--no-playlist", "--no-mtime", "--no-colors", "--no-part",
                    "-P", DownloaderController.folder.path,
                    "-o", "%(title).60B [%(id)s].%(ext)s",
                    "--progress-template", "download:@@P %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
                    "--print", "before_dl:@@T %(title)s",
                    "--print", "after_move:@@F %(filepath)s",
                    "--no-simulate",
                    "-N", "8",                       // 分片视频 8 路同时下
                    ] + Tools.commonArgs()
        let ff = Tools.ffmpeg
        switch quality.indexOfSelectedItem {
        case 1: args += ff != nil ? ["-S", "res:1080,fps,vcodec:h264,acodec:aac", "--merge-output-format", "mp4"] : ["-f", "b[height<=1080]/b"]
        case 2: args += ff != nil ? ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"] : ["-f", "ba"]
        default: args += ff != nil ? ["-S", "res,fps,vcodec:h264,acodec:aac", "--merge-output-format", "mp4"] : ["-f", "b"]
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = args
        p.environment = Tools.env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        job.process = p
        var errText = ""
        var stage = 0   // 第几个文件（视频+音频分开下载时有两段）

        func handle(_ line: String) {
            if line.hasPrefix("@@T ") {
                let t = String(line.dropFirst(4))
                job.update { job.title = "\(LinkParser.siteName(job.link))：\(t)" }
            } else if line.hasPrefix("@@F ") {
                job.files.append(URL(fileURLWithPath: String(line.dropFirst(4))))
            } else if line.hasPrefix("@@P ") {
                let parts = line.dropFirst(4).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                let pct = Double(parts.first?.replacingOccurrences(of: "%", with: "") ?? "") ?? 0
                if pct < job.progress * 100 - 50 { stage += 1 }   // 进度从头开始 = 开始下第二段（音频）
                job.update {
                    job.progress = pct / 100
                    let speed = parts.count > 1 ? parts[1] : ""
                    let eta = parts.count > 2 ? parts[2] : ""
                    job.detail = "\(stage > 0 ? "下载音频" : "下载中") \(String(format: "%.0f%%", pct))　\(speed == "NA" || speed == "Unknown B/s" ? "" : speed)　\(eta == "NA" || eta == "Unknown" ? "" : "剩 " + eta)"
                }
            } else if line.contains("[Merger]") || line.contains("[ExtractAudio]") || line.contains("[VideoConvertor]") {
                job.update { job.detail = "正在合成画面和声音…" }
            } else if line.hasPrefix("[") && job.progress == 0 {
                job.update { job.detail = "正在解析…" }
            }
        }

        func reader(_ pipe: Pipe, isErr: Bool) {
            var buf = Data()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                buf.append(d)
                while let i = buf.firstIndex(of: 0x0A) {
                    let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    buf.removeSubrange(buf.startIndex...i)
                    DispatchQueue.main.async {
                        if isErr { if line.contains("ERROR") { errText = line } } else { handle(line) }
                    }
                }
            }
        }
        reader(out, isErr: false)
        reader(err, isErr: true)

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard job.state == .running else { return }
                if proc.terminationStatus == 0 {
                    let f = job.files.last
                    self?.finish(job, file: f) {
                        let size = f.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) } ?? 0
                        let res = f.map { DownloaderController.resolution(of: $0) } ?? ""
                        return "✅ 完成\(res.isEmpty ? "" : " · " + res) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) · \(f?.lastPathComponent ?? "")"
                    }
                } else {
                    job.update { job.state = .failed; job.detail = DownloaderController.explain(errText, link: job.link) }
                }
            }
        }
        do { try p.run(); job.update { job.detail = "正在解析…" } }
        catch { job.update { job.state = .failed; job.detail = "启动下载组件失败：\(error.localizedDescription)" } }
    }

    /// 读一下下载好的视频是多大分辨率
    static func resolution(of url: URL) -> String {
        guard let ffprobe = Tools.find("ffprobe") else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "" : s
    }

    static func explain(_ err: String, link: URL) -> String {
        let e = err.lowercased()
        if e.contains("cookie") || e.contains("login") || e.contains("sign in") || e.contains("登录") {
            return "这个视频要登录才能下载：在上面选「用 xx 的登录」（选你平时登录这个网站的浏览器），再点重试"
        }
        if e.contains("unsupported url") { return "暂不支持这个网站的链接" }
        if e.contains("private") || e.contains("not available") || e.contains("removed") { return "视频不存在、已删除或不公开" }
        if e.contains("timed out") || e.contains("connection") || e.contains("network") { return "网络连接失败（YouTube 等境外网站需要能访问）" }
        if e.contains("no video formats") { return "没找到视频：链接可能不完整，请复制 App 里「分享 → 复制链接」的完整文字" }
        return err.isEmpty ? "下载失败，可以点「更新下载组件」后重试" : String(err.replacingOccurrences(of: "ERROR: ", with: "").prefix(160))
    }

    private func notifyDone(_ job: DownloadJob) {
        if let cb = job.onFinished, let f = job.files.last(where: { ClipEditor.isVideo($0) }) {
            job.onFinished = nil
            cb(f)
            return
        }
        if !window.isKeyWindow { Toast.show("下载完成：\(job.title.prefix(24))") }
    }

    @objc private func updateTools() {
        guard let (exe, args) = Tools.updateCommand() else {
            Tools.installYtdlp { [weak self] ok in
                self?.refreshFooter()
                self?.footer.stringValue = ok ? "下载组件已安装" : "安装失败，请检查网络"
            }
            footer.stringValue = "正在安装下载组件…"
            return
        }
        footer.stringValue = "正在更新下载组件…"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = Tools.env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.refreshFooter()
                self?.footer.stringValue = proc.terminationStatus == 0 ? "✅ 下载组件已是最新" : "更新没成功，请检查网络"
            }
        }
        try? p.run()
    }
}
