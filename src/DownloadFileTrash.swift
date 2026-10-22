import Foundation

/// Only the exact files recorded for one download may be moved. Never remove permanently.
enum DownloadFileTrash {
    struct Report {
        var trashed: [URL] = []
        var remaining: [URL] = []
        var missing = 0
        var errors: [String] = []
    }

    static func move(_ files: [URL]) -> Report {
        let fm = FileManager.default
        var report = Report()
        var seen = Set<String>()
        for file in files {
            let url = file.standardizedFileURL
            guard seen.insert(url.absoluteString).inserted else { continue }
            do {
                guard file.isFileURL else {
                    throw NSError(domain: "DownloadFileTrash", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "只能删除本地文件"])
                }
                let attrs = try fm.attributesOfItem(atPath: url.path)
                let type = attrs[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else {
                    throw NSError(domain: "DownloadFileTrash", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "为保护素材，不删除文件夹或特殊文件"])
                }
                var destination: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &destination)
                if let destination = destination { report.trashed.append(destination as URL) }
                else { report.trashed.append(url) }
            } catch {
                let e = error as NSError
                if e.domain == NSCocoaErrorDomain &&
                    (e.code == NSFileNoSuchFileError || e.code == NSFileReadNoSuchFileError) {
                    report.missing += 1
                } else {
                    report.remaining.append(file)
                    report.errors.append("\(file.lastPathComponent)：\(error.localizedDescription)")
                }
            }
        }
        return report
    }
}

struct DownloadHistoryEntry: Codable {
    let link: URL
    let title: String
    let detail: String
    let files: [URL]
}
