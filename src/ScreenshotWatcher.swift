import Cocoa
import Darwin
import ImageIO

/// Read the screenshot directory itself: Spotlight may stop reporting new files.
final class ScreenshotWatcher: NSObject {
    private let directory: URL?
    private let store: ShelfStore
    private let startedAt: Date
    private var timer: Timer?
    private var seen = Set<URL>()
    private var pending = Set<URL>()
    private var warned = Set<URL>()

    init(directory: URL? = nil, since: Date = Date(), store: ShelfStore = .shared) {
        self.directory = directory; startedAt = since; self.store = store
        super.init()
    }
    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scan() }
        timer?.tolerance = 0.4
    }

    func scan() {
        let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() + "/Desktop")
        let folder = directory ?? URL(fileURLWithPath: location, isDirectory: true)
        guard folder.resolvingSymlinksInPath() != store.dir.resolvingSymlinksInPath(),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for url in files where !seen.contains(url) && !pending.contains(url) {
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard let created = values.creationDate, created >= startedAt.addingTimeInterval(-2) else { seen.insert(url); continue }
            // Check the actual macOS marker, not a filename that might belong to an unrelated image.
            guard Self.isScreenshot(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { continue }
            pending.insert(url)
            store.importFiles([url]) { [weak self] added, _ in
                guard let self else { return }
                self.pending.remove(url)
                if added > 0 { self.seen.insert(url) }
                else if self.warned.insert(url).inserted { Toast.show("截图尚未存入中转站，将自动重试；原图仍在截图保存目录。") }
            }
        }
    }

    static func isScreenshot(_ url: URL) -> Bool {
        let key = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 4096 else { return false }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard count == size, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSNumber else { return false }
        return value.boolValue
    }
}
