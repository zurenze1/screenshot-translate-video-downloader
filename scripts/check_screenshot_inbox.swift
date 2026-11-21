// Compile with src/ScreenshotWatcher.swift and src/RelayStore.swift.
// All files and imports stay inside an isolated temporary directory.
import Cocoa
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum Toast { static func show(_ message: String) {} }

@main struct InboxChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("toolbox-inbox-check-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let inbox = root.appendingPathComponent("screenshots")
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let relay = ShelfStore(directory: root.appendingPathComponent("relay"))
        let watcher = ScreenshotWatcher(directory: inbox, since: Date().addingTimeInterval(-60), store: relay)
        let color = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemGreen.cgColor); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!
        func png(_ url: URL, marked: Bool = true) throws {
            let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(output, image, nil)
            precondition(CGImageDestinationFinalize(output))
            if marked { try mark(url) }
        }
        func mark(_ url: URL) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
            let result = data.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, data.count, 0, 0) }
            precondition(result == 0)
        }
        func settle(_ store: ShelfStore) {
            let deadline = Date().addingTimeInterval(5)
            while store.isImporting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            precondition(!store.isImporting, "import did not finish")
            store.reload()
        }
        func check(_ expected: Int, _ label: String) {
            watcher.scan(); settle(relay)
            precondition(relay.items.count == expected, "\(label): \(relay.items.count) != \(expected)")
            print("PASS " + label)
        }
        let ordinary = inbox.appendingPathComponent("截图名字但并非系统截图.png")
        try png(ordinary, marked: false)
        check(0, "unrelated image ignored")
        let old = inbox.appendingPathComponent("old.png")
        try png(old); try fm.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        check(0, "pre-start screenshot ignored")
        let fresh = inbox.appendingPathComponent("fresh.png")
        try png(fresh)
        watcher.scan(); watcher.scan(); settle(relay)
        precondition(relay.items.count == 1)
        check(1, "new screenshot imported once without Spotlight")
        let partial = inbox.appendingPathComponent("partial.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: partial); try mark(partial)
        check(1, "unfinished image waits")
        try png(partial)
        check(2, "finished image collected on retry")
        let link = inbox.appendingPathComponent("symlink.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: fresh)
        check(2, "symlink ignored")

        let retryInbox = root.appendingPathComponent("retry-inbox")
        try fm.createDirectory(at: retryInbox, withIntermediateDirectories: true)
        let retryImage = retryInbox.appendingPathComponent("retry.png"); try png(retryImage)
        let blocked = root.appendingPathComponent("blocked-relay")
        try Data([0]).write(to: blocked)
        let retryStore = ShelfStore(directory: blocked)
        let retryWatcher = ScreenshotWatcher(directory: retryInbox, since: Date().addingTimeInterval(-60), store: retryStore)
        retryWatcher.scan(); settle(retryStore); precondition(retryStore.items.isEmpty)
        try fm.removeItem(at: blocked); try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        retryWatcher.scan(); settle(retryStore); precondition(retryStore.items.count == 1)
        print("PASS failed import retries after destination recovers")
        precondition(fm.fileExists(atPath: fresh.path) && fm.fileExists(atPath: retryImage.path))
        print("PASS original screenshots preserved")
    }
}
