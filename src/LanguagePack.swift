// 下载苹果离线翻译语言包：装好后英↔中在本机秒出，不用联网
import Cocoa
import SwiftUI
import Translation

@available(macOS 15.0, *)
private struct PackView: View {
    @State private var config: TranslationSession.Configuration?
    @State private var message = "点「下载」后，系统会弹出确认框，点「下载」即可。\n装好后英文 ↔ 中文在本机秒出，不用联网，也更稳定。"
    @State private var working = false
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("下载离线翻译包").font(.title3.bold())
            Text(message).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
            HStack {
                Button("在系统设置里管理…") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        NSWorkspace.shared.open(u)
                    }
                }
                Spacer()
                Button("关闭") { done() }
                Button(working ? "下载中…" : "下载") {
                    working = true
                    config = TranslationSession.Configuration(source: Locale.Language(identifier: "en"),
                                                              target: Locale.Language(identifier: "zh-Hans"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .translationTask(config) { session in
            do {
                try await session.prepareTranslation()
                if #available(macOS 26.0, *) { await AppleEngine.shared.forget() }
                await MainActor.run { message = "✅ 已装好。现在翻译会优先用本机离线翻译。"; working = false }
            } catch {
                await MainActor.run {
                    message = "没装成功：\(error.localizedDescription)\n可以点「在系统设置里管理」，在「翻译语言」里手动下载「英语」和「中文（简体）」。"
                    working = false
                }
            }
        }
    }
}

enum LanguagePack {
    private static var window: NSWindow?

    static func show() {
        guard #available(macOS 15.0, *) else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "离线翻译包"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PackView(done: { window?.close() }))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 还没装语言包时，新版本第一次启动提醒一次
    static func remindIfNeeded() {
        guard #available(macOS 26.0, *), !UserDefaults.standard.bool(forKey: "packReminded") else { return }
        Task { @MainActor in
            let ok = await AppleEngine.shared.installed(from: "en", to: "zh-Hans")
            UserDefaults.standard.set(true, forKey: "packReminded")
            if !ok { show() }
        }
    }
}
