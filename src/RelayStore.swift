import Foundation
import UniformTypeIdentifiers

/// 沿用原截图目录，既有图片不迁移。所有导入均保存副本，原文件保持原位。
final class ShelfStore {
    static let shared = ShelfStore()
    let dir: URL
    private(set) var items: [URL] = []
    private var listeners: [() -> Void] = []
    private let importer = DispatchQueue(label: "com.zurenze.toolbox.relay-import", qos: .userInitiated)
    private(set) var importCount = 0
    var isImporting: Bool { importCount > 0 }

    init(directory: URL? = nil) {
        dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("桌面翻译器/截图中转站", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }
    func observe(_ f: @escaping () -> Void) { listeners.append(f) }
    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        items = files.filter {
            let v = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return v?.isRegularFile == true && v?.isSymbolicLink != true
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a > b
        }
        DispatchQueue.main.async { self.listeners.forEach { $0() } }
    }
    func uniqueURL(_ name: String) -> URL {
        let safe = URL(fileURLWithPath: name).lastPathComponent
        var url = dir.appendingPathComponent(safe)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(base + " (\(i))" + (ext.isEmpty ? "" : "." + ext)); i += 1
        }
        return url
    }
    func newShotURL() -> URL {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return uniqueURL("截图 \(fmt.string(from: Date())).png")
    }
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    @discardableResult func add(copyOf source: URL) -> Bool {
        guard Self.accepts(source), source.deletingLastPathComponent().resolvingSymlinksInPath().path != dir.resolvingSymlinksInPath().path else { return false }
        let temporary = dir.appendingPathComponent(".import-" + UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            let destination = uniqueURL(source.lastPathComponent)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try? FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: destination.path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }
    /// 大视频在独立串行队列复制，避免卡住主界面；中间文件完成前不可见。
    func importFiles(_ urls: [URL], completion: @escaping (Int, Int) -> Void) {
        importCount += 1; listeners.forEach { $0() }
        importer.async {
            var added = 0
            for url in urls { if self.add(copyOf: url) { added += 1 } }
            DispatchQueue.main.async {
                self.importCount -= 1; self.reload(); completion(added, urls.count - added)
            }
        }
    }
    /// 只移除本站顶层的真实文件；失败时保留，不降级为永久删除。
    @discardableResult func remove(_ urls: [URL]) -> Int {
        var removed = 0
        for url in urls where url.isFileURL && url.deletingLastPathComponent().resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path && Self.accepts(url) {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); removed += 1 } catch { }
        }
        reload(); return removed
    }
}

enum RelayKind: Int {
    case all = 0, image, video, file
    static func of(_ url: URL) -> RelayKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return .file
    }
    var title: String { switch self { case .all: return "全部"; case .image: return "图片"; case .video: return "视频"; case .file: return "文件" } }
}
