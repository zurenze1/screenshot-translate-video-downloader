import Cocoa

/// 从同一个悬浮入口打开已安装的独立工具，继续使用各工具自己的权限与设置。
enum CompanionTool {
    case workbench

    private var appName: String {
        switch self {
        case .workbench: return "祖仁泽自媒体工作台"
        }
    }

    private var bundleID: String {
        switch self {
        case .workbench: return "local.zrz.media-workbench"
        }
    }

    func open() {
        let localPaths = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/01_软件开发与小工具", isDirectory: true)]
        let url = localPaths.map { $0.appendingPathComponent(appName + ".app", isDirectory: true) }
            .first { Bundle(url: $0)?.bundleIdentifier == bundleID }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let appURL = url else {
            showError("请先将“\(appName).app”安装到“应用程序”，再从这里打开。")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
        }
    }

    private func showError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "暂时无法打开\(appName)"
        alert.informativeText = detail
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
