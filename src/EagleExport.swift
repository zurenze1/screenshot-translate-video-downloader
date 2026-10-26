import AppKit

private final class EagleExportDocument: NSView { override var isFlipped: Bool { true } }

/// Uses only Eagle's loopback HTTP API. Originals in the relay are never moved.
struct EagleAPI {
    struct Folder { let id: String; let title: String }
    static func request(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var parts = URLComponents(string: "http://127.0.0.1:41595/api/" + path)!
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 30
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["status"] as? String == "success" else { throw error("Eagle 未成功响应，请检查 Eagle 与当前素材库。") }
        return json
    }
    static func folders() async throws -> [Folder] {
        let json = try await request("folder/list")
        var result: [Folder] = []
        func walk(_ entries: [[String: Any]], _ parent: String) {
            for entry in entries {
                guard let id = entry["id"] as? String, let name = entry["name"] as? String else { continue }
                let title = parent.isEmpty ? name : parent + " / " + name
                result.append(Folder(id: id, title: title)); walk(entry["children"] as? [[String: Any]] ?? [], title)
            }
        }
        walk(json["data"] as? [[String: Any]] ?? [], ""); return result
    }
    static func matchingIDs(name: String, folder: String) async throws -> Set<String> {
        let json = try await request("item/list", query: [.init(name: "folders", value: folder), .init(name: "keyword", value: name), .init(name: "limit", value: "200"), .init(name: "orderBy", value: "-CREATEDATE")])
        return Set((json["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["name"] as? String == name, (item["folders"] as? [String] ?? []).contains(folder), item["isDeleted"] as? Bool != true else { return nil }
            return item["id"] as? String
        })
    }
    static func add(_ url: URL, name: String, annotation: String, folder: String) async throws {
        let previous = try await matchingIDs(name: name, folder: folder)
        let result = try await request("item/addFromPath", body: ["path": url.path, "name": name, "annotation": annotation, "folderId": folder])
        let returnedID = (result["data"] as? [String: Any])?["id"] as? String
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let current = try await matchingIDs(name: name, folder: folder)
            if let returnedID, current.contains(returnedID) { return }
            if !current.subtracting(previous).isEmpty { return }
        }
        throw error("Eagle 已接收请求，但尚未查到新增素材。请先在 Eagle 核对，避免重复导入。")
    }
    static func error(_ message: String) -> NSError { NSError(domain: "ToolboxEagle", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor final class EagleExportController: NSObject, NSWindowDelegate {
    static let shared = EagleExportController()
    private var panel: NSPanel?
    private var files: [URL] = []
    private var folders: [EagleAPI.Folder] = []
    private let picker = NSPopUpButton()
    private let annotation = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let send = NSButton(title: "导入所选素材", target: nil, action: nil)
    private let rows = NSStackView()
    private var names: [NSTextField] = []
    private var busy = false
    func canTerminate() -> Bool {
        guard busy else { return true }
        if let panel { ToolWindowPresenter.show(panel) }; Toast.show("正在核对 Eagle 导入，请完成后再退出工具箱。"); return false
    }
    func show(urls: [URL]) {
        guard !busy else { if let panel { ToolWindowPresenter.show(panel) }; return }
        guard !urls.isEmpty else { Toast.show("请先在中转站选中要存入 Eagle 的素材。"); return }
        files = urls; names = []
        if panel == nil { build() }
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        for url in urls {
            let source = NSTextField(labelWithString: url.lastPathComponent); source.font = .systemFont(ofSize: 11); source.textColor = .secondaryLabelColor; source.lineBreakMode = .byTruncatingMiddle
            let field = NSTextField(string: url.deletingPathExtension().lastPathComponent); field.placeholderString = "Eagle 中的素材名称"
            names.append(field)
            let pair = NSStackView(views: [source, field]); pair.orientation = .vertical; pair.alignment = .leading; pair.spacing = 4
            rows.addArrangedSubview(pair); pair.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true; field.widthAnchor.constraint(equalTo: pair.widthAnchor).isActive = true; source.widthAnchor.constraint(equalTo: pair.widthAnchor).isActive = true
        }
        annotation.stringValue = ""; send.title = "导入所选素材"; send.isEnabled = false; picker.removeAllItems(); status.stringValue = "正在读取 Eagle 的文件夹，请保持 Eagle 开启。"
        ProductTheme.styleButton(send)
        ToolWindowPresenter.show(panel!)
        Task { await loadFolders() }
    }
    private func build() {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.title = "中转站 → Eagle"; p.isReleasedWhenClosed = false; p.delegate = self; p.minSize = NSSize(width: 540, height: 460); p.level = .floating
        let header = ProductTheme.header("COLLECT / EAGLE", "选好位置，再收进素材库。", "本机连接 Eagle · 可逐项命名 · 中转站原件保留")
        annotation.placeholderString = "共同备注（可选）"
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 14
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = EagleExportDocument(); scroll.documentView = document
        rows.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(rows); document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12), rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        send.target = self; send.action = #selector(importSelected); send.bezelStyle = .rounded
        ProductTheme.primary(send)
        let refresh = NSButton(title: "刷新文件夹", target: self, action: #selector(refreshFolders))
        let footer = NSStackView(views: [send, refresh]); footer.spacing = 12
        let stack = NSStackView(views: [header, picker, scroll, annotation, status, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false; p.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: p.contentView!.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: p.contentView!.bottomAnchor, constant: -20), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)])
        [picker, scroll, annotation, status].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        ProductTheme.apply(to: p); p.center(); panel = p
    }
    @objc private func refreshFolders() { guard !busy else { return }; Task { await loadFolders() } }
    private func loadFolders() async {
        send.isEnabled = false
        do {
            folders = try await EagleAPI.folders(); picker.removeAllItems(); picker.addItems(withTitles: folders.map(\.title))
            let preferred = UserDefaults.standard.string(forKey: "eagleExportFolder")
            if let index = folders.firstIndex(where: { $0.id == preferred }) { picker.selectItem(at: index) }
            status.stringValue = folders.isEmpty ? "当前 Eagle 素材库没有文件夹，请先在 Eagle 新建文件夹，再刷新。" : "已连接 Eagle · \(files.count) 项素材 · 请选择目标文件夹"
            send.isEnabled = !folders.isEmpty
        } catch { status.stringValue = "无法连接 Eagle，请先打开 Eagle 并载入素材库，再刷新。\n\(error.localizedDescription)" }
    }
    @objc private func importSelected() {
        guard !busy, folders.indices.contains(picker.indexOfSelectedItem) else { return }
        let titles = names.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !titles.contains(where: { $0.isEmpty }) else { status.stringValue = "每项素材都需要名称。"; return }
        let folder = folders[picker.indexOfSelectedItem]; let note = annotation.stringValue
        busy = true; send.isEnabled = false; picker.isEnabled = false; annotation.isEnabled = false; names.forEach { $0.isEnabled = false }
        UserDefaults.standard.set(folder.id, forKey: "eagleExportFolder")
        Task {
            var confirmed: [URL] = []; var failed: [(URL, String)] = []
            for (index, url) in files.enumerated() {
                status.stringValue = "正在导入并核对 \(index + 1) / \(files.count)：\(titles[index])"
                do { try await EagleAPI.add(url, name: titles[index], annotation: note, folder: folder.id); confirmed.append(url) }
                catch { failed.append((url, error.localizedDescription)) }
            }
            busy = false; picker.isEnabled = true; annotation.isEnabled = true; names.forEach { $0.isEnabled = true }
            if failed.isEmpty {
                status.stringValue = "已在 Eagle「\(folder.title)」确认新增 \(confirmed.count) 项。中转站原件保留。"
                send.title = "已完成"; send.isEnabled = false
            } else {
                status.stringValue = "已确认 \(confirmed.count) 项；\(failed.count) 项未确认。\n" + failed.map { "\($0.0.lastPathComponent)：\($0.1)" }.joined(separator: "\n")
                send.title = "请关闭后重新选择未导入项"; send.isEnabled = false
            }
            ProductTheme.styleButton(send)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if busy { status.stringValue = "正在导入与核对，请等待完成。"; return false }; return true }
}
