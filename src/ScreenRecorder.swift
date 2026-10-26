import AppKit
import AVKit
import ScreenCaptureKit

/// Entry remains available on macOS 14; native recording requires macOS 15.
enum RecordingEntry {
    @MainActor static func show() {
        if #available(macOS 15.0, *) { ScreenRecorder.shared.show() }
        else { Toast.show("录屏需要 macOS 15 或更新版本，其余工具仍可使用。") }
    }
    @MainActor static func canTerminate() -> Bool {
        if #available(macOS 15.0, *), ScreenRecorder.shared.isCapturing { ScreenRecorder.shared.show(); Toast.show("请先停止录制，等待文件写入完成后退出。"); return false }
        return true
    }
}

private final class RecordingRegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
private final class RecordingRegionView: NSView {
    var completed: ((CGRect?) -> Void)?
    private var origin: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
        if !selection.isEmpty {
            NSColor.clear.setFill(); selection.fill(using: .copy)
            NSColor.systemGreen.setStroke(); let p = NSBezierPath(rect: selection); p.lineWidth = 2; p.stroke()
        }
        let text = "拖出录制区域 · Esc 取消"
        text.draw(at: CGPoint(x: 28, y: bounds.height - 55), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white])
    }
    override func mouseDown(with event: NSEvent) { origin = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }; let p = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(p.x, origin.x), y: min(p.y, origin.y), width: abs(p.x-origin.x), height: abs(p.y-origin.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 32, selection.height >= 32 else { return }
        completed?(selection)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { completed?(nil) } else { super.keyDown(with: event) } }
}

@available(macOS 15.0, *)
@MainActor final class ScreenRecorder: NSObject, NSWindowDelegate, SCRecordingOutputDelegate, SCStreamDelegate {
    static let shared = ScreenRecorder()
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let displays = NSPopUpButton()
    private let systemAudio = NSButton(checkboxWithTitle: "电脑声音", target: nil, action: nil)
    private let microphone = NSButton(checkboxWithTitle: "麦克风", target: nil, action: nil)
    private let quick = NSButton(checkboxWithTitle: "快速录制：停止后直接存入中转站", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "选择区域后开始，录完可预览并命名。")
    private let start = NSButton(title: "开始录制", target: nil, action: nil)
    private let choose = NSButton(title: "选择区域…", target: nil, action: nil)
    private let full = NSButton(title: "整个屏幕", target: nil, action: nil)
    private var screens: [NSScreen] = []
    private var region: CGRect?
    private var overlay: NSPanel?
    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var pendingURL: URL?
    private var active = false
    private var starting = false
    private var finishing = false
    private var timer: Timer?
    private var quickForTake = false
    var isCapturing: Bool { active || starting || finishing }
    private var preview: NSPanel?
    private let player = AVPlayerView()
    private let name = NSTextField()
    private let save = NSButton(title: "保存到中转站", target: nil, action: nil)
    private var staging: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("工具箱/录屏暂存", isDirectory: true)
    }
    private override init() {
        super.init()
        panel.title = "录屏"; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.delegate = self
        displays.target = self; displays.action = #selector(displayChanged)
        systemAudio.state = .on
        choose.target = self; choose.action = #selector(selectRegion)
        full.target = self; full.action = #selector(selectFull)
        start.target = self; start.action = #selector(startOrStop)
        let folder = NSButton(title: "打开录屏暂存", target: self, action: #selector(openStaging))
        let head = ProductTheme.header("CAPTURE / 录屏", "把需要的画面，留在手边。", "本机录制 · MP4 · 区域 / 全屏 · 声音独立选择")
        let audio = NSStackView(views: [systemAudio, microphone]); audio.spacing = 26
        let area = NSStackView(views: [choose, full]); area.spacing = 12
        let controls = NSStackView(views: [start, folder]); controls.spacing = 12
        let stack = NSStackView(views: [head, displays, area, audio, quick, status, controls])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 22), status.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        ProductTheme.apply(to: panel); panel.center()
    }
    func show() {
        if isCapturing { ToolWindowPresenter.show(panel); return }
        if !active && !starting && !finishing {
            screens = NSScreen.screens; displays.removeAllItems()
            displays.addItems(withTitles: screens.enumerated().map { "屏幕 \($0.offset + 1) · \($0.element.localizedName)" })
            region = nil
        }
        if pendingURL != nil { showPreview() } else { ToolWindowPresenter.show(panel) }
    }
    @objc private func displayChanged() { region = nil; status.stringValue = "已切换屏幕，请选择区域或使用整个屏幕。" }
    @objc private func selectFull() { region = nil; status.stringValue = "将录制所选整个屏幕。" }
    @objc private func openStaging() {
        do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true); NSWorkspace.shared.open(staging) }
        catch { showError(error.localizedDescription) }
    }
    @objc private func selectRegion() {
        guard !active, !starting, let screen = screens[safe: displays.indexOfSelectedItem] else { return }
        panel.orderOut(nil)
        let window = RecordingRegionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "选择录屏区域"
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RecordingRegionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.completed = { [weak self] rect in
            guard let self else { return }
            self.overlay?.orderOut(nil); self.overlay = nil
            if let rect {
                // ScreenCaptureKit uses top-left display points; AppKit uses bottom-left.
                self.region = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
                self.status.stringValue = "已选区域：\(Int(rect.width)) × \(Int(rect.height)) 点"
            }
            ToolWindowPresenter.show(self.panel)
        }
        window.contentView = view; overlay = window; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
    }
    @objc private func startOrStop() {
        if active { stopRecording(); return }
        guard !starting, !finishing, pendingURL == nil else { return }
        starting = true; controlsEnabled(false); start.isEnabled = false; status.stringValue = "正在准备录屏权限与设备…"
        Task { await beginRecording() }
    }
    private func beginRecording() async {
        do {
            guard let screen = screens[safe: displays.indexOfSelectedItem], let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { throw recordingError("没有可用屏幕，请重新打开录屏。") }
            let captureMic = microphone.state == .on
            if captureMic {
                let permission = AVCaptureDevice.authorizationStatus(for: .audio)
                var allowed = permission == .authorized
                if permission == .notDetermined { allowed = await microphonePermission() }
                guard allowed else { throw recordingError("麦克风未获授权。请在系统设置「隐私与安全性 → 麦克风」中允许工具箱，或关闭麦克风开关。") }
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { throw recordingError("未找到所选屏幕。") }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let rect = region ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
            config.sourceRect = rect
            let scale = min(screen.backingScaleFactor, 3840 / rect.width, 2160 / rect.height)
            config.width = max(2, Int(rect.width * scale) / 2 * 2); config.height = max(2, Int(rect.height * scale) / 2 * 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30); config.queueDepth = 6
            config.showsCursor = true; config.capturesAudio = systemAudio.state == .on
            config.excludesCurrentProcessAudio = true; config.sampleRate = 48000; config.channelCount = 2
            config.captureMicrophone = captureMic
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let url = staging.appendingPathComponent("录屏-\(UUID().uuidString).mp4")
            let outputConfig = SCRecordingOutputConfiguration(); outputConfig.outputURL = url
            outputConfig.videoCodecType = .h264; outputConfig.outputFileType = .mp4
            let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            try capture.addRecordingOutput(output)
            pendingURL = url; stream = capture; recording = output; quickForTake = quick.state == .on
            try await capture.startCapture()
        } catch {
            stream = nil; recording = nil; pendingURL = nil; starting = false; active = false; finishing = false
            controlsEnabled(true); start.isEnabled = true; start.title = "开始录制"; showError(error.localizedDescription)
        }
    }
    private func microphonePermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    private func controlsEnabled(_ enabled: Bool) { [displays, choose, full, systemAudio, microphone, quick].forEach { $0.isEnabled = enabled } }
    private func stopRecording() {
        guard active, !finishing else { return }; finishing = true; start.isEnabled = false
        status.stringValue = "正在写入 MP4，请稍候…"; timer?.invalidate(); timer = nil
        Task {
            do { try await stream?.stopCapture() }
            catch { recordingFailed(error.localizedDescription) }
        }
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.starting = false; self.active = true
            self.start.title = "停止录制"; self.start.isEnabled = true
            self.status.stringValue = "● 正在录制 00:00 · 停止后写入 MP4"
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }; let seconds = Int(self.recording?.recordedDuration.seconds ?? 0)
                    self.status.stringValue = String(format: "● 正在录制 %02d:%02d · 停止后写入 MP4", seconds / 60, seconds % 60)
                }
            }
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { [weak self] in self?.finished() }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.recordingFailed(error.localizedDescription) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.recordingFailed(error.localizedDescription) }
    }
    private func finished() {
        guard active || starting || finishing else { return }
        resetCapture()
        guard let url = pendingURL, FileManager.default.fileExists(atPath: url.path) else { pendingURL = nil; showError("录屏没有生成可用文件。"); return }
        if quickForTake { name.stringValue = defaultName(); saveRecording() }
        else { showPreview() }
    }
    private func resetCapture() {
        timer?.invalidate(); timer = nil; active = false; starting = false; finishing = false
        stream = nil; recording = nil; controlsEnabled(true); start.isEnabled = true; start.title = "开始录制"
    }
    private func recordingFailed(_ message: String) {
        guard active || starting || finishing else { return }
        let failedStream = stream; resetCapture(); pendingURL = nil
        Task { try? await failedStream?.stopCapture() }
        showError("录制未完成：\(message)\n如已写入片段，可在「打开录屏暂存」中找回。")
    }
    private func defaultName() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return "录屏 \(f.string(from: Date()))"
    }
    private func showPreview() {
        guard let url = pendingURL else { return }
        if preview == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            p.title = "录屏预览 · 命名后存入中转站"; p.isReleasedWhenClosed = false; p.delegate = self; p.minSize = NSSize(width: 560, height: 420)
            name.placeholderString = "素材名称"; save.target = self; save.action = #selector(saveRecording)
            let hint = NSTextField(wrappingLabelWithString: "关闭预览会保留暂存文件，再次打开录屏可继续保存。")
            hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 12)
            let row = NSStackView(views: [name, save]); row.spacing = 12
            let stack = NSStackView(views: [player, row, hint]); stack.orientation = .vertical; stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false; p.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: p.contentView!.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: p.contentView!.bottomAnchor, constant: -20), player.widthAnchor.constraint(equalTo: stack.widthAnchor), player.heightAnchor.constraint(greaterThanOrEqualToConstant: 280), row.widthAnchor.constraint(equalTo: stack.widthAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor)])
            ProductTheme.apply(to: p); p.center(); preview = p
        }
        name.stringValue = defaultName(); player.player = AVPlayer(url: url)
        player.controlsStyle = .default; panel.orderOut(nil); ToolWindowPresenter.show(preview!, focus: name)
        player.player?.play()
    }
    @objc private func saveRecording() {
        guard let source = pendingURL else { return }
        let cleaned = name.stringValue.components(separatedBy: CharacterSet(charactersIn: "/:\n\r\0")).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { showError("请填写素材名称。"); return }
        save.isEnabled = false
        let target = ShelfStore.shared.uniqueURL(String(cleaned.prefix(120)) + ".mp4")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.copyItem(at: source, to: target)
                DispatchQueue.main.async {
                    self.pendingURL = nil; self.save.isEnabled = true; self.player.player?.pause(); self.player.player = nil
                    self.preview?.orderOut(nil); ShelfStore.shared.reload()
                    try? FileManager.default.removeItem(at: source)
                    self.status.stringValue = "已存入中转站：\(target.lastPathComponent)"; ToolWindowPresenter.show(self.panel)
                    Toast.show("录屏已保存到中转站")
                }
            } catch {
                DispatchQueue.main.async { self.save.isEnabled = true; self.showError("保存失败，暂存文件仍在：\(error.localizedDescription)") }
            }
        }
    }
    private func showError(_ message: String) {
        status.stringValue = message
        let alert = NSAlert(); alert.messageText = "录屏"; alert.informativeText = message
        alert.beginSheetModal(for: preview?.isVisible == true ? preview! : panel)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel && (active || starting || finishing) { status.stringValue = "请先停止录制，等待 MP4 写入完成。"; return false }
        if sender === preview { player.player?.pause() }
        return true
    }
    private func recordingError(_ message: String) -> NSError { NSError(domain: "ToolboxRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
