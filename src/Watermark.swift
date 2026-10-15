// 自动找水印：在整段视频里均匀取十几帧，画面在变、某个角落的笔画却一直不动 → 那就是水印
import Cocoa
import AVFoundation

enum Watermark {
    /// 返回水印框（0~1 的比例坐标，原点在左上），找不到返回空
    static func detect(frames: [CGImage]) -> [CGRect] {
        guard frames.count >= 4 else { return [] }
        let W = 384
        let H = max(8, Int(Double(W) * Double(frames[0].height) / Double(max(1, frames[0].width))))
        let n = W * H
        var edgeCount = [UInt16](repeating: 0, count: n)
        var sum = [Float](repeating: 0, count: n), sq = [Float](repeating: 0, count: n)
        var used = 0
        var prev: [UInt8]?
        var moving = 0
        for img in frames {
            guard let g = gray(img, W, H) else { continue }
            used += 1
            for y in 1..<(H - 1) {
                for x in 1..<(W - 1) {
                    let i = y * W + x
                    let gx = abs(Int(g[i + 1]) - Int(g[i - 1]))
                    let gy = abs(Int(g[i + W]) - Int(g[i - W]))
                    if gx + gy > 40 { edgeCount[i] += 1 }
                    let v = Float(g[i]); sum[i] += v; sq[i] += v * v
                }
            }
            if let p = prev {   // 画面有没有在变（全是静止画面就没法判断）
                var diff = 0
                for i in stride(from: 0, to: n, by: 7) where abs(Int(g[i]) - Int(p[i])) > 20 { diff += 1 }
                if diff > n / 7 / 20 { moving += 1 }
            }
            prev = g
        }
        guard used >= 4, moving >= used / 3 else { return [] }

        // 一直有笔画、亮度又几乎不变的像素
        var cand = [Bool](repeating: false, count: n)
        let need = UInt16(max(2, Int(Double(used) * 0.45)))
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                guard edgeCount[i] >= need else { continue }
                let m = sum[i] / Float(used)
                let sd = (sq[i] / Float(used) - m * m).squareRoot()
                // 只看四个角附近（水印几乎都在角上）
                let corner = (x < W * 2 / 5 || x > W * 3 / 5) && (y < H / 4 || y > H * 3 / 4)
                if sd < 22 && corner { cand[i] = true }
            }
        }
        // 膨胀一下，把一个水印的字连成一块
        var grown = cand
        let r = 2
        for y in 0..<H { for x in 0..<W where cand[y * W + x] {
            for dy in -r...r { for dx in -r...r {
                let xx = x + dx, yy = y + dy
                if xx >= 0, yy >= 0, xx < W, yy < H { grown[yy * W + xx] = true }
            } }
        } }
        // 连通块
        var label = [Int32](repeating: 0, count: n)
        var boxes: [(CGRect, Int)] = []
        var stack: [Int] = []
        var next: Int32 = 1
        for s in 0..<n where grown[s] && label[s] == 0 {
            var minX = W, minY = H, maxX = 0, maxY = 0, strong = 0
            var pts: [(Int, Int)] = []
            label[s] = next; stack = [s]
            while let i = stack.popLast() {
                let x = i % W, y = i / W
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if cand[i] { strong += 1; pts.append((x, y)) }
                for j in [i - 1, i + 1, i - W, i + W] where j >= 0 && j < n && grown[j] && label[j] == 0 {
                    if (j == i - 1 && x == 0) || (j == i + 1 && x == W - 1) { continue }
                    label[j] = next; stack.append(j)
                }
            }
            next += 1
            // 去掉只有一两像素厚的细线（旁边的字幕线、边框），只留笔画密的主体
            if !pts.isEmpty {
                var col = [Int](repeating: 0, count: W), row = [Int](repeating: 0, count: H)
                for (x, y) in pts { col[x] += 1; row[y] += 1 }
                let thick = 3
                while minX < maxX && col[minX] < thick { minX += 1 }
                while maxX > minX && col[maxX] < thick { maxX -= 1 }
                while minY < maxY && row[minY] < thick { minY += 1 }
                while maxY > minY && row[maxY] < thick { maxY -= 1 }
            }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            // 太小是噪点；太大、太宽（比如黑边、画面边框）不像水印
            guard strong >= 30, bw < W * 45 / 100, bh < H / 5, bw > 6, bh > 4 else { continue }
            boxes.append((CGRect(x: minX, y: minY, width: bw, height: bh), strong))
        }
        let pad: CGFloat = 2
        return boxes.sorted { $0.1 > $1.1 }.prefix(3).map { b in
            let r = b.0.insetBy(dx: -pad, dy: -pad)
            return CGRect(x: max(0, r.minX) / CGFloat(W), y: max(0, r.minY) / CGFloat(H),
                          width: min(r.width, CGFloat(W) - max(0, r.minX)) / CGFloat(W),
                          height: min(r.height, CGFloat(H) - max(0, r.minY)) / CGFloat(H))
        }
    }

    private static func gray(_ img: CGImage, _ W: Int, _ H: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: W * H)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let c = CGContext(data: p.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            c.interpolationQuality = .medium
            // 位图内存第 0 行就是画面最上面一行
            c.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        return ok ? buf : nil
    }

    /// 从视频（本地文件或在线地址）里均匀取帧
    static func sampleFrames(_ asset: AVAsset, duration: Double, count: Int = 16) async -> [CGImage] {
        guard duration > 1 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var out: [CGImage] = []
        for k in 0..<count {
            let t = duration * (0.04 + 0.92 * Double(k) / Double(max(1, count - 1)))
            if let (img, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) { out.append(img) }
        }
        return out
    }

    /// 在线视频（或系统读不了的格式）：用 ffmpeg 并行从各个时间点各取一帧
    static func sampleFrames(url: URL, headers: [String: String], duration: Double, count: Int = 14) async -> [CGImage] {
        guard duration > 1, let ffmpeg = Tools.ffmpeg else { return [] }
        let times = (0..<count).map { duration * (0.04 + 0.92 * Double($0) / Double(max(1, count - 1))) }
        return await withTaskGroup(of: CGImage?.self) { g in
            for t in times {
                g.addTask {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: ffmpeg)
                    var a = ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.2f", t)]
                    if let ua = headers["User-Agent"] { a += ["-user_agent", ua] }
                    let rest = headers.filter { $0.key != "User-Agent" }.map { "\($0.key): \($0.value)\r\n" }.joined()
                    if !rest.isEmpty { a += ["-headers", rest] }
                    a += ["-i", url.isFileURL ? url.path : url.absoluteString, "-frames:v", "1", "-vf", "scale=640:-2",
                          "-f", "image2pipe", "-vcodec", "png", "-"]
                    p.arguments = a
                    p.environment = Tools.env
                    let pipe = Pipe()
                    p.standardOutput = pipe
                    p.standardError = FileHandle.nullDevice
                    guard (try? p.run()) != nil else { return nil }
                    let d = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(src, 0, nil)
                }
            }
            var out: [CGImage] = []
            for await img in g { if let i = img { out.append(i) } }
            return out
        }
    }

    /// 比例框 → ffmpeg delogo 滤镜（视频像素宽高）
    static func delogoFilter(_ rects: [CGRect], width: Int, height: Int) -> String? {
        let parts: [String] = rects.compactMap { r in
            var x = Int((r.minX * CGFloat(width)).rounded()), y = Int((r.minY * CGFloat(height)).rounded())
            var w = Int((r.width * CGFloat(width)).rounded()), h = Int((r.height * CGFloat(height)).rounded())
            x = max(1, x); y = max(1, y)
            w = min(w, width - x - 1); h = min(h, height - y - 1)
            guard w >= 2, h >= 2 else { return nil }
            return "delogo=x=\(x):y=\(y):w=\(w):h=\(h)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }
}

// MARK: - 下载完自动去水印（直接替换原文件，只留一个文件）

enum WatermarkRemover {
    /// 找到水印就重新编码抹掉并替换原文件；没找到就什么都不动
    static func process(_ file: URL, progress: @escaping (String, Double) -> Void, done: @escaping (_ removed: Bool, _ error: String?) -> Void) {
        guard let ffmpeg = Tools.ffmpeg else { done(false, nil); return }
        Task { @MainActor in
            progress("正在检查有没有水印…", 0)
            let asset = AVURLAsset(url: file)
            let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            var size = CGSize.zero
            var rate: Float = 0
            if let t = try? await asset.loadTracks(withMediaType: .video).first,
               let (ns, tf, r0) = try? await t.load(.naturalSize, .preferredTransform, .estimatedDataRate) {
                let r = CGRect(origin: .zero, size: ns).applying(tf)
                size = CGSize(width: abs(r.width), height: abs(r.height))
                rate = r0
            }
            let frames = await Watermark.sampleFrames(asset, duration: dur)
            let rects = await Task.detached { Watermark.detect(frames: frames) }.value
            guard !rects.isEmpty, size.width > 0,
                  let filter = Watermark.delogoFilter(rects, width: Int(size.width), height: Int(size.height)) else {
                done(false, nil); return
            }
            let tmp = file.deletingLastPathComponent().appendingPathComponent(".去水印中-\(UUID().uuidString.prefix(6)).\(file.pathExtension.isEmpty ? "mp4" : file.pathExtension)")
            // 码率封顶在原视频的 1.3 倍左右：画质看不出差别，文件也不会比原来大很多
            let kbps = Int(rate / 1000)
            let capArgs = kbps > 200 ? ["-maxrate", "\(kbps * 13 / 10)k", "-bufsize", "\(kbps * 26 / 10)k"] : []
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-hide_banner", "-nostdin", "-y", "-i", file.path, "-map", "0:v:0", "-map", "0:a?",
                           "-vf", filter, "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p"] + capArgs + [
                           "-tag:v", "avc1", "-c:a", "copy", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", tmp.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { h.readabilityHandler = nil; return }
                let s = String(decoding: d, as: UTF8.self)
                if let r = s.range(of: #"out_time_us=(\d+)"#, options: .regularExpression),
                   let us = Double(s[r].split(separator: "=")[1]), dur > 0 {
                    let f = min(1, us / 1_000_000 / dur)
                    DispatchQueue.main.async { progress(String(format: "发现水印，正在抹掉 %.0f%%", f * 100), f) }
                }
            }
            p.terminationHandler = { proc in
                DispatchQueue.main.async {
                    if proc.terminationStatus == 0 {
                        // 用去好水印的文件替换原文件，硬盘上只留一份
                        try? FileManager.default.removeItem(at: file)
                        if (try? FileManager.default.moveItem(at: tmp, to: file)) != nil { done(true, nil) }
                        else { done(false, "替换文件失败") }
                    } else {
                        try? FileManager.default.removeItem(at: tmp)
                        done(false, "去水印没成功，保留了原视频")
                    }
                }
            }
            do { try p.run() } catch { done(false, error.localizedDescription) }
        }
    }
}
