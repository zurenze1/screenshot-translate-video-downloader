// 翻译引擎：苹果离线翻译（装了语言包就秒出）→ 必应 → 谷歌 → MyMemory，全部免费、无需注册
import Foundation
import NaturalLanguage
import Translation

enum Engine: Int, CaseIterable {
    case apple = 0, bing, google, mymemory
    var name: String {
        switch self {
        case .apple: return "苹果离线"
        case .bing: return "必应翻译"
        case .google: return "谷歌翻译"
        case .mymemory: return "MyMemory"
        }
    }
}

struct TranslationResult { let text: String; let engine: Engine; let toChinese: Bool }

struct TError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Translator {
    static let shared = Translator()
    let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 5
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()
    let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0"

    /// 最近失败过的引擎先跳过一会儿，免得每次都白等超时
    private var failedAt: [Engine: Date] = [:]
    private let lock = NSLock()
    private func recentlyFailed(_ e: Engine) -> Bool {
        lock.withLock { failedAt[e].map { Date().timeIntervalSince($0) < 90 } ?? false }
    }
    private func mark(_ e: Engine, ok: Bool) {
        lock.withLock { failedAt[e] = ok ? nil : Date() }
    }

    /// 文字以中文为主就译成英文，否则译成中文
    static func isMostlyChinese(_ s: String) -> Bool {
        var cjk = 0, latin = 0
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) { cjk += 1 }
            else if u.isASCII && CharacterSet.letters.contains(u) { latin += 1 }
        }
        return cjk > 0 && cjk * 3 >= latin
    }

    /// 启动时先拿好必应的令牌，第一次翻译就不用等
    func warmUp() {
        Task.detached { _ = try? await self.bing.token() }
        if #available(macOS 26.0, *) {
            Task.detached { _ = await AppleEngine.shared.installed(from: "en", to: "zh-Hans") }
        }
    }

    /// only 为 nil 时按 苹果离线 → 必应 → 谷歌 → MyMemory 顺序自动切换
    func translate(_ text: String, only: Engine?) async throws -> TranslationResult {
        let toZh = !Translator.isMostlyChinese(text)
        var order: [Engine] = only.map { [$0] } ?? Engine.allCases
        if only == nil {
            let fresh = order.filter { !recentlyFailed($0) }
            if !fresh.isEmpty { order = fresh + order.filter { !fresh.contains($0) } }
        }
        var errors: [String] = []
        for e in order {
            do {
                let r: String
                switch e {
                case .apple: r = try await apple(text, toZh: toZh)
                case .bing: r = try await bing.translate(text, toZh: toZh)
                case .google: r = try await google(text, toZh: toZh)
                case .mymemory: r = try await myMemory(text, toZh: toZh)
                }
                let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    mark(e, ok: true)
                    return TranslationResult(text: t, engine: e, toChinese: toZh)
                }
                errors.append("\(e.name)：返回为空")
            } catch {
                if Task.isCancelled { throw error }
                if e != .apple { mark(e, ok: false) }
                errors.append("\(e.name)：\(error.localizedDescription)")
            }
        }
        throw TError(message: errors.joined(separator: "\n"))
    }

    func check(_ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { throw TError(message: "服务器返回 \(code)") }
    }

    // MARK: 苹果离线翻译

    static func detectLanguage(_ s: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(s)
        return r.dominantLanguage?.rawValue
    }

    private func apple(_ text: String, toZh: Bool) async throws -> String {
        guard #available(macOS 26.0, *) else { throw TError(message: "需要 macOS 26") }
        let src = Translator.detectLanguage(text) ?? (toZh ? "en" : "zh-Hans")
        let dst = toZh ? "zh-Hans" : "en"
        guard src != dst else { return text }
        guard await AppleEngine.shared.installed(from: src, to: dst) else {
            throw TError(message: "还没下载离线语言包（菜单栏「译」→ 下载离线翻译包）")
        }
        return try await AppleEngine.shared.translate([text], from: src, to: dst).first ?? ""
    }

    // MARK: 必应

    let bing = BingEngine()

    // MARK: 谷歌（国内可能被拦）

    func google(_ text: String, toZh: Bool) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [URLQueryItem(name: "client", value: "gtx"),
                            URLQueryItem(name: "sl", value: "auto"),
                            URLQueryItem(name: "tl", value: toZh ? "zh-CN" : "en"),
                            URLQueryItem(name: "dt", value: "t")]
        var r = URLRequest(url: comps.url!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = "q=\(Translator.formEncode(text))".data(using: .utf8)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await session.data(for: r)
        try check(resp)
        guard let arr = try JSONSerialization.jsonObject(with: d) as? [Any],
              let segs = arr.first as? [Any] else { throw TError(message: "结果格式不对") }
        return segs.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }

    private func myMemory(_ text: String, toZh: Bool) async throws -> String {
        var comps = URLComponents(string: "https://api.mymemory.translated.net/get")!
        comps.queryItems = [URLQueryItem(name: "q", value: String(text.prefix(480))),
                            URLQueryItem(name: "langpair", value: toZh ? "en|zh-CN" : "zh-CN|en")]
        let (d, resp) = try await session.data(from: comps.url!)
        try check(resp)
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rd = obj["responseData"] as? [String: Any],
              let out = rd["translatedText"] as? String else { throw TError(message: "结果格式不对") }
        return out
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: 整屏翻译用的批量翻译（多国语言 → 简体中文）

    func batchToChinese(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        var out = texts
        var todo = Array(texts.indices)

        // 1. 苹果离线：按语言分组，装了语言包的直接本机翻
        if #available(macOS 26.0, *) {
            var byLang: [String: [Int]] = [:]
            for i in todo { byLang[Translator.detectLanguage(texts[i]) ?? "en", default: []].append(i) }
            var left: [Int] = []
            for (lang, idx) in byLang {
                guard lang != "zh-Hans", await AppleEngine.shared.installed(from: lang, to: "zh-Hans"),
                      let rs = try? await AppleEngine.shared.translate(idx.map { texts[$0] }, from: lang, to: "zh-Hans"),
                      rs.count == idx.count else { left += idx; continue }
                for (k, i) in idx.enumerated() { out[i] = rs[k] }
            }
            todo = left
        }
        if todo.isEmpty { return out }

        // 2. 必应：多段拼成一次请求
        if !recentlyFailed(.bing) {
            do {
                let rs = try await bing.batch(todo.map { texts[$0] })
                for (k, i) in todo.enumerated() { out[i] = rs[k] }
                mark(.bing, ok: true)
                return out
            } catch { mark(.bing, ok: false) }
        }

        // 3. 谷歌：一段一段并行
        var anyOK = false
        try await withThrowingTaskGroup(of: (Int, String?).self) { g in
            for i in todo { g.addTask { (i, try? await self.google(texts[i], toZh: true)) } }
            for try await (i, s) in g { if let s = s, !s.isEmpty { out[i] = s; anyOK = true } }
        }
        if !anyOK && todo.count == texts.count { throw TError(message: "翻译服务都连不上") }
        return out
    }
}

// MARK: - 必应网页版翻译（国内可直接访问）

final class BingEngine {
    private struct Tok { let ig: String; let iid: String; let key: String; let token: String; let host: String; let date: Date }
    private var tok: Tok?
    private var counter = 1
    private var fetching: Task<Tok, Error>?
    private let lock = NSLock()

    fileprivate func token() async throws -> Any { try await getToken() }

    private func getToken() async throws -> Tok {
        enum Have { case tok(Tok), wait(Task<Tok, Error>), none }
        let have: Have = lock.withLock {
            if let t = tok, Date().timeIntervalSince(t.date) < 50 * 60 { return .tok(t) }
            if let f = fetching { return .wait(f) }
            return .none
        }
        switch have {
        case .tok(let t): return t
        case .wait(let f): return try await f.value
        case .none: break
        }
        let f = Task<Tok, Error> {
            var r = URLRequest(url: URL(string: "https://www.bing.com/translator")!)
            r.setValue(Translator.shared.ua, forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 6
            let (d, resp) = try await Translator.shared.session.data(for: r)
            try Translator.shared.check(resp)
            let html = String(decoding: d, as: UTF8.self)
            func find(_ pattern: String) -> String? {
                guard let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let rg = Range(m.range(at: 1), in: html) else { return nil }
                return String(html[rg])
            }
            guard let ig = find("IG:\"([A-Za-z0-9]+)\""),
                  let key = find("params_AbusePreventionHelper\\s*=\\s*\\[(\\d+),"),
                  let token = find("params_AbusePreventionHelper\\s*=\\s*\\[\\d+,\"([^\"]+)\"") else {
                throw TError(message: "拿不到必应授权")
            }
            let iid = find("data-iid=\"([^\"]+)\"") ?? "translator.5023"
            let host = resp.url?.host ?? "www.bing.com"
            return Tok(ig: ig, iid: iid, key: key, token: token, host: host, date: Date())
        }
        lock.withLock { fetching = f }
        do {
            let t = try await f.value
            lock.withLock { tok = t; fetching = nil }
            return t
        } catch {
            lock.withLock { fetching = nil }
            throw error
        }
    }

    private func request(_ text: String, to: String, from: String = "auto-detect") async throws -> String {
        for attempt in 0..<2 {
            let t = try await getToken()
            let n: Int = lock.withLock { counter += 1; return counter }
            var r = URLRequest(url: URL(string: "https://\(t.host)/ttranslatev3?isVertical=1&IG=\(t.ig)&IID=\(t.iid).\(n)")!)
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.setValue(Translator.shared.ua, forHTTPHeaderField: "User-Agent")
            r.setValue("https://\(t.host)/translator", forHTTPHeaderField: "Referer")
            let body = ["fromLang": from, "to": to, "text": text, "key": t.key, "token": t.token]
                .map { "\($0.key)=\(Translator.formEncode($0.value))" }.joined(separator: "&")
            r.httpBody = body.data(using: .utf8)
            let (d, resp) = try await Translator.shared.session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200,
               let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]],
               let trs = arr.first?["translations"] as? [[String: Any]],
               let out = trs.first?["text"] as? String {
                return out
            }
            // 令牌过期或被限流：换新令牌再试一次
            lock.withLock { tok = nil }
            if attempt == 1 { throw TError(message: "服务器返回 \(code)") }
        }
        throw TError(message: "必应没有返回结果")
    }

    /// 单段（长文按段落切成 ≤900 字一块）
    func translate(_ text: String, toZh: Bool) async throws -> String {
        let to = toZh ? "zh-Hans" : "en"
        let chunks = BingEngine.chunk(text, limit: 900)
        if chunks.count == 1 { return try await request(text, to: to) }
        let parts = try await withThrowingTaskGroup(of: (Int, String).self) { g -> [String] in
            for (i, c) in chunks.enumerated() { g.addTask { (i, try await self.request(c, to: to)) } }
            var out = Array(repeating: "", count: chunks.count)
            for try await (i, s) in g { out[i] = s }
            return out
        }
        return parts.joined(separator: "\n")
    }

    /// 多段一次翻：用换行拼起来，按行拆回；对不上就逐段翻
    func batch(_ texts: [String]) async throws -> [String] {
        let clean = texts.map { $0.replacingOccurrences(of: "\n", with: " ") }
        // 按语言分组（一次请求里混着英文、法文、日文时，必应只认一种）
        var byLang: [String: [Int]] = [:]
        for (i, t) in clean.enumerated() { byLang[Translator.detectLanguage(t) ?? "auto-detect", default: []].append(i) }
        var groups: [(String, [Int])] = []
        for (lang, idx) in byLang {
            let from = BingEngine.bingCode(lang)
            var cur: [Int] = [], len = 0
            for i in idx {
                if len + clean[i].count > 900 && !cur.isEmpty { groups.append((from, cur)); cur = []; len = 0 }
                cur.append(i); len += clean[i].count + 1
            }
            if !cur.isEmpty { groups.append((from, cur)) }
        }
        var out = clean
        try await withThrowingTaskGroup(of: [(Int, String)].self) { g in
            for (from, idx) in groups {
                g.addTask {
                    let joined = idx.map { clean[$0] }.joined(separator: "\n")
                    let r = try await self.request(joined, to: "zh-Hans", from: from)
                    let lines = r.components(separatedBy: "\n")
                    if lines.count == idx.count { return Array(zip(idx, lines)) }
                    var res: [(Int, String)] = []
                    for i in idx { res.append((i, (try? await self.request(clean[i], to: "zh-Hans", from: from)) ?? clean[i])) }
                    return res
                }
            }
            for try await part in g { for (i, s) in part { out[i] = s } }
        }
        return out
    }

    /// 系统识别出的语言代码 → 必应的语言代码；认不准的交给必应自己判断
    static func bingCode(_ lang: String) -> String {
        let known: Set<String> = ["en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "ar", "th", "vi", "id", "ms",
                                  "nl", "pl", "tr", "uk", "sv", "da", "fi", "nb", "cs", "el", "he", "hi", "hu", "ro", "zh-Hant"]
        return known.contains(lang) ? lang : "auto-detect"
    }

    static func chunk(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var out: [String] = []
        var cur = ""
        for para in text.components(separatedBy: "\n") {
            var p = para
            while p.count > limit {   // 一段太长就按句子切
                let head = String(p.prefix(limit))
                let cut = head.lastIndex(where: { ".!?。！？;；".contains($0) }).map { head.index(after: $0) } ?? head.endIndex
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append(String(head[..<cut]))
                p = String(p.dropFirst(head.distance(from: head.startIndex, to: cut)))
            }
            if cur.count + p.count + 1 > limit { out.append(cur); cur = p }
            else { cur = cur.isEmpty ? p : cur + "\n" + p }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - 苹果系统自带的离线翻译（macOS 26 起可在后台直接用）

@available(macOS 26.0, *)
actor AppleEngine {
    static let shared = AppleEngine()
    private var sessions: [String: TranslationSession] = [:]
    private var status: [String: (Bool, Date)] = [:]

    func installed(from src: String, to dst: String) async -> Bool {
        let k = "\(src)>\(dst)"
        if let (ok, d) = status[k], Date().timeIntervalSince(d) < (ok ? 600 : 20) { return ok }
        let s = await LanguageAvailability().status(from: Locale.Language(identifier: src),
                                                   to: Locale.Language(identifier: dst))
        let ok = s == .installed
        status[k] = (ok, Date())
        return ok
    }

    func translate(_ texts: [String], from src: String, to dst: String) async throws -> [String] {
        let k = "\(src)>\(dst)"
        let s: TranslationSession
        if let x = sessions[k] { s = x } else {
            s = TranslationSession(installedSource: Locale.Language(identifier: src),
                                   target: Locale.Language(identifier: dst))
            sessions[k] = s
        }
        do {
            if texts.count == 1 { return [try await s.translate(texts[0]).targetText] }
            let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
            let rs = try await s.translations(from: reqs)
            var out = texts
            for r in rs { if let id = r.clientIdentifier, let i = Int(id) { out[i] = r.targetText } }
            return out
        } catch {
            sessions[k] = nil
            status[k] = nil
            throw error
        }
    }

    func forget() { status.removeAll() }
}
