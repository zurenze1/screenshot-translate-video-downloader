import Cocoa
import UniformTypeIdentifiers

private enum ToolLinkAddress {
    static func parse(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let parts = URLComponents(string: text.contains("://") ? text : "https://" + text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}

struct ToolboxLink: Codable, Identifiable {
    enum Kind: String, Codable { case application, webpage }
    let id: UUID
    let title: String
    let kind: Kind
    let target: String
}

@MainActor final class ToolboxLinks: NSObject {
    static let shared = ToolboxLinks()
    private(set) var items: [ToolboxLink] = []
    var onChange: (() -> Void)?
    private let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/桌面翻译器/toolbox-links.json")
    override init() {
        super.init()
        if let data = try? Data(contentsOf: storage), let saved = try? JSONDecoder().decode([ToolboxLink].self, from: data) { items = saved }
    }
    func open(_ item: ToolboxLink) {
        switch item.kind {
        case .application:
            let url = URL(fileURLWithPath: item.target)
            guard FileManager.default.fileExists(atPath: url.path) else { error("这个应用已经移动，请重新添加。") ; return }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, failure in
                if let failure { DispatchQueue.main.async { self.error(failure.localizedDescription) } }
            }
        case .webpage:
            guard let url = ToolLinkAddress.parse(item.target) else { error("网页地址无效，请重新添加。") ; return }
            NSWorkspace.shared.open(url)
        }
    }
    func promptToAdd() {
        let prompt = NSAlert(); prompt.messageText = "添加到工具箱"
        prompt.informativeText = "把已安装的应用或常用网页放进来，以后从这里直接打开。"
        prompt.addButton(withTitle: "选择应用"); prompt.addButton(withTitle: "添加网页"); prompt.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        switch prompt.runModal() {
        case .alertFirstButtonReturn: addApplication()
        case .alertSecondButtonReturn: addWebpage()
        default: break
        }
    }
    private func addApplication() {
        let picker = NSOpenPanel(); picker.title = "选择要加入工具箱的应用"
        picker.allowedContentTypes = [.applicationBundle]; picker.canChooseDirectories = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications"); picker.prompt = "加入工具箱"
        guard picker.runModal() == .OK, let url = picker.url?.resolvingSymlinksInPath(), let bundle = Bundle(url: url), bundle.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let title = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        saveAdding(ToolboxLink(id: UUID(), title: title, kind: .application, target: url.path))
    }
    private func addWebpage() {
        let name = NSTextField(); name.placeholderString = "工具名称"
        let address = NSTextField(); address.placeholderString = "https://…"
        let fields = NSStackView(views: [name, address]); fields.orientation = .vertical; fields.spacing = 10
        fields.frame = NSRect(x: 0, y: 0, width: 340, height: 64)
        for field in [name, address] { field.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        let prompt = NSAlert(); prompt.messageText = "添加常用网页"; prompt.accessoryView = fields
        prompt.addButton(withTitle: "加入工具箱"); prompt.addButton(withTitle: "取消")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let url = ToolLinkAddress.parse(address.stringValue) else { error("请填写名称和有效的网页地址。") ; return }
        saveAdding(ToolboxLink(id: UUID(), title: title, kind: .webpage, target: url.absoluteString))
    }
    private func saveAdding(_ item: ToolboxLink) {
        guard !items.contains(where: { $0.kind == item.kind && $0.target == item.target }) else { error("这个工具已经在列表里了。") ; return }
        persist(items + [item])
    }
    @objc func removeFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        persist(items.filter { $0.id != id })
    }
    private func persist(_ updated: [ToolboxLink]) {
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: storage, options: .atomic)
            items = updated; onChange?()
        } catch { self.error("列表保存失败：\(error.localizedDescription)") }
    }
    private func error(_ message: String) {
        let alert = NSAlert(); alert.messageText = "工具箱"; alert.informativeText = message; alert.runModal()
    }
}
