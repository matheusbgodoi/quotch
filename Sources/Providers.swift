import Foundation
import AppKit
import SwiftUI
import SQLite3
import Security

/// Uma leitura de cota: fração usada (a "manchete") + as janelas detalhadas.
struct UsageReading {
    var fraction: Double        // anel de fora: janela curta (sessão/diário)
    var inner: Double? = nil    // anel de dentro: semanal
    var windows: [QuotaWindow]
    var fetchedAt: Date
}

final class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge, completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) } else { h(.performDefaultHandling, nil) }
    }
}
let insecureSession = URLSession(configuration: .default, delegate: InsecureDelegate(), delegateQueue: nil)

enum ProviderError: Error { case noCredential, badResponse(String), http(Int), rateLimited(TimeInterval) }

/// Contratos exatos levantados na dissecação (docs/dissecacao/providers-e-dados.md).
enum Providers {
    static let interval: TimeInterval = 300

    static func fetch(_ kind: ProviderKind, allowKeychain: Bool, vaulted: VaultedCredential? = nil) async throws -> UsageReading {
        switch kind {
        case .cursor:
            if let v = vaulted, let a = v.fields["authId"], let t = v.fields["accessToken"] { return try await cursor(authId: a, token: t) }
            return try await cursor()
        case .codex:
            if let v = vaulted {   // leitura local pertence à conta ativa: para a capturada, vale a última foto
                if let r = v.lastReading { return UsageReading(fraction: r.fraction, windows: r.windows.map { QuotaWindow(label: $0.label, resetText: $0.resetText, fraction: $0.fraction) }, fetchedAt: r.fetchedAt) }
                throw ProviderError.noCredential
            }
            return try codex()
        case .claude:
            if let v = vaulted, let t = v.fields["accessToken"] { return try await claude(token: t) }
            return try await claude()   // adicionar "from Claude Code" já é o consentimento
        case .antigravity:
            if let r = try? await antigravityBridge() { return r }
            return try await antigravity()
        case .flow: throw ProviderError.noCredential
        case .grok: throw ProviderError.noCredential   // só via navegador (cookie)
        }
    }

    // MARK: Grok — POST grok.com/rest/rate-limits com os cookies do navegador (sso/sso-rw).
    // Anel de fora = grok-4 (o mais escasso), anel de dentro = grok-3. Reset diário.
    static func grokBrowser(source: BrowserSource) async throws -> UsageReading {
        let c = BrowserCookies.cookies(host: "grok.com", source: source)
        guard c["sso"] != nil || c["sso-rw"] != nil else { throw ProviderError.noCredential }
        let header = c.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        func rate(_ model: String) async -> (rem: Double, tot: Double, window: Double)? {
            var req = URLRequest(url: URL(string: "https://grok.com/rest/rate-limits")!)
            req.httpMethod = "POST"
            req.setValue(header, forHTTPHeaderField: "Cookie")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("https://grok.com", forHTTPHeaderField: "Origin")
            req.setValue("https://grok.com/", forHTTPHeaderField: "Referer")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["requestKind": "DEFAULT", "modelName": model])
            req.timeoutInterval = 12
            guard let (d, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let rem = (j["remainingQueries"] as? NSNumber)?.doubleValue,
                  let tot = (j["totalQueries"] as? NSNumber)?.doubleValue else { return nil }
            return (rem, tot, (j["windowSizeSeconds"] as? NSNumber)?.doubleValue ?? 86400)
        }
        guard let g4 = await rate("grok-4") else { throw ProviderError.badResponse("Grok: sessão expirada") }
        func label(_ r: (rem: Double, tot: Double, window: Double), _ name: String) -> String {
            "\(Int(r.rem))/\(Int(r.tot)) \(name)"
        }
        let outer = g4.tot > 0 ? max(0, (g4.tot - g4.rem) / g4.tot) : 0
        var windows = [QuotaWindow(label: label(g4, "grok-4 today"), resetText: "", fraction: outer)]
        var inner: Double? = nil
        if let g3 = await rate("grok-3"), g3.tot > 0 {
            inner = max(0, (g3.tot - g3.rem) / g3.tot)
            windows.append(QuotaWindow(label: label(g3, "grok-3 today"), resetText: "", fraction: inner!))
        }
        return UsageReading(fraction: outer, inner: inner, windows: windows, fetchedAt: Date())
    }

    // MARK: Cursor — GET usage-summary com Cookie WorkosCursorSessionToken=<authId>%3A%3A<token>
    static func cursor() async throws -> UsageReading {
        guard let auth = cursorItem("cursorAuth/stripeMembershipAuthId"),
              let token = cursorItem("cursorAuth/accessToken") else { throw ProviderError.noCredential }
        return try await cursor(authId: auth, token: token)
    }
    static func cursorBrowser(source: BrowserSource) async throws -> UsageReading {
        let c = BrowserCookies.cookies(host: "cursor.com", source: source)
        guard let full = c["WorkosCursorSessionToken"] else { throw ProviderError.noCredential }
        var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        req.setValue("WorkosCursorSessionToken=\(full)", forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
        return parseCursorUsage(j)
    }
    static func claudeBrowserIdentity(source: BrowserSource) -> AccountIdentity? {
        guard let (header, org) = claudeCookieHeader(source) else { return nil }
        let sem = DispatchSemaphore(value: 0); var ident: AccountIdentity?
        var r = URLRequest(url: URL(string: "https://claude.ai/api/bootstrap")!)
        r.setValue(header, forHTTPHeaderField: "Cookie"); r.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15", forHTTPHeaderField: "User-Agent"); r.timeoutInterval = 15
        _ = org
        URLSession.shared.dataTask(with: r) { d,_,_ in defer { sem.signal() }
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String:Any], let a = j["account"] as? [String:Any] else { return }
            ident = AccountIdentity(email: a["email_address"] as? String ?? a["email"] as? String, name: a["full_name"] as? String, plan: nil)
        }.resume()
        _ = sem.wait(timeout: .now()+16)
        return ident
    }
    static func cursor(authId auth: String, token: String) async throws -> UsageReading {
        var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        req.setValue("WorkosCursorSessionToken=\(auth)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ProviderError.http(code) }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.badResponse("json") }
        let iu = j["individualUsage"] as? [String: Any]
        let plan = iu?["plan"] as? [String: Any]
        let pct = (plan?["totalPercentUsed"] as? Double) ?? 0
        let end = isoDate(j["billingCycleEnd"] as? String)
        var windows = [QuotaWindow(label: "Included usage", resetText: resetText(end), fraction: pct / 100)]
        if let od = iu?["onDemand"] as? [String: Any], (od["enabled"] as? Bool) == true,
           let used = od["used"] as? Double, let limit = od["limit"] as? Double, limit > 0 {
            windows.append(QuotaWindow(label: "On demand", resetText: resetText(end), fraction: used / limit))
        }
        let headline = windows.map(\.fraction).max() ?? pct/100
        return UsageReading(fraction: headline, windows: windows, fetchedAt: Date())
    }

    static func cursorItem(_ key: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quotch-cur-\(getpid()).vscdb").path
        for suf in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + suf) }
        guard (try? FileManager.default.copyItem(atPath: path, toPath: tmp)) != nil else { return nil }
        for suf in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suf) {
            try? FileManager.default.copyItem(atPath: path + suf, toPath: tmp + suf)
        }
        defer { for suf in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + suf) } }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    // MARK: Codex — sem rede: último evento token_count dos rollouts recentes
    static func codex() throws -> UsageReading {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home.appendingPathComponent(".codex/state_5.sqlite").path
        guard FileManager.default.fileExists(atPath: dbPath) else { throw ProviderError.noCredential }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quotch-codex-\(getpid()).sqlite").path
        for suf in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + suf) }
        guard (try? FileManager.default.copyItem(atPath: dbPath, toPath: tmp)) != nil else { throw ProviderError.noCredential }
        for suf in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: dbPath + suf) {
            try? FileManager.default.copyItem(atPath: dbPath + suf, toPath: tmp + suf)
        }
        defer { for suf in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + suf) } }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw ProviderError.noCredential }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 8", -1, &st, nil) == SQLITE_OK else {
            throw ProviderError.badResponse("threads")
        }
        defer { sqlite3_finalize(st) }
        var paths: [String] = []
        while sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) { paths.append(String(cString: c)) }
        guard !paths.isEmpty else { throw ProviderError.badResponse("No Codex threads on this machine yet") }

        // Lê só a cauda de cada rollout e pega o último token_count com rate_limits.
        for p in paths {
            guard let h = FileHandle(forReadingAtPath: p) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let tail: UInt64 = 256 * 1024
            try? h.seek(toOffset: size > tail ? size - tail : 0)
            guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"token_count\""), let d = line.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let payload = j["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any] else { continue }
                var windows: [QuotaWindow] = []
                var headline: Double = 0
                for (id, label) in [("primary", nil), ("secondary", nil)] as [(String, String?)] {
                    guard let w = rl[id] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
                    let mins = (w["window_minutes"] as? Double) ?? 0
                    let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    let name = label ?? (mins >= 10080 ? "Weekly limit" : mins >= 1440 ? "Daily limit" : mins > 0 ? "5-hour limit" : "Current session")
                    windows.append(QuotaWindow(label: name, resetText: resetText(reset), fraction: used / 100))
                    headline = max(headline, used / 100)
                }
                guard !windows.isEmpty else { continue }
                let weekly = windows.first(where: { $0.label.lowercased().contains("week") })?.fraction
                let session = windows.first(where: { !$0.label.lowercased().contains("week") })?.fraction ?? headline
                return UsageReading(fraction: session, inner: (weekly != nil && windows.count > 1) ? weekly : nil, windows: windows, fetchedAt: Date())
            }
        }
        throw ProviderError.badResponse("Codex has not recorded a usage snapshot yet")
    }

    // MARK: Claude — Keychain "Claude Code-credentials" → GET /api/oauth/usage (limits[])
    static func claudeKeychainJSON() -> [String: Any]? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "Claude Code-credentials",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let rc = SecItemCopyMatching(q as CFDictionary, &out)
        QTLog.write("claude keychain rc=\(rc) hasData=\(out is Data)")
        guard rc == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    static func claude() async throws -> UsageReading {
        guard let j = claudeKeychainJSON(), let oauth = j["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { throw ProviderError.noCredential }
        return try await claude(token: token)
    }
    static func claude(token: String) async throws -> UsageReading {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (rd, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 429 {
            throw ProviderError.rateLimited(Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
        }
        guard http?.statusCode == 200, let r = try? JSONSerialization.jsonObject(with: rd) as? [String: Any] else {
            throw ProviderError.http(http?.statusCode ?? 0)
        }
        var windows: [QuotaWindow] = []
        let labels = ["session": "Current session", "weekly_all": "All models", "weekly_opus": "Opus", "weekly_sonnet": "Sonnet"]
        if let limits = r["limits"] as? [[String: Any]] {
            for l in limits {
                guard let kind = l["kind"] as? String, let pct = l["percent"] as? Double,
                      let ra = l["resets_at"] as? String else { continue }
                let reset = isoDate(ra)
                windows.append(QuotaWindow(label: labels[kind] ?? kind.replacingOccurrences(of: "_", with: " ").capitalized,
                                           resetText: resetText(reset), fraction: pct / 100))
            }
        }
        if windows.isEmpty {   // fallback: five_hour / seven_day com utilization
            for (k, name) in [("five_hour", "Current session"), ("seven_day", "All models")] {
                guard let b = r[k] as? [String: Any], let u = b["utilization"] as? Double else { continue }
                let reset = isoDate(b["resets_at"] as? String)
                windows.append(QuotaWindow(label: name, resetText: resetText(reset), fraction: u / 100))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse("no limits") }
        let headline = windows.max(by: { $0.fraction < $1.fraction })!.fraction   // a que está limitando
        return UsageReading(fraction: headline, windows: windows, fetchedAt: Date())
    }

    /// ISO 8601 com ou sem fração de segundo.
    static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        return f1.date(from: s) ?? f2.date(from: s)
    }

    // MARK: Claude via NAVEGADOR (perfil do Chrome) — multi-conta real
    private static func claudeCookieHeader(_ source: BrowserSource) -> (header: String, org: String)? {
        let c = BrowserCookies.cookies(host: "claude.ai", source: source)
        guard let sk = c["sessionKey"], let org = c["lastActiveOrg"] else { return nil }
        var h = "sessionKey=\(sk)"
        for k in ["sessionKeyV3", "cf_clearance", "lastActiveOrg", "__cf_bm"] { if let v = c[k] { h += "; \(k)=\(v)" } }
        return (h, org)
    }
    private static func claudeRequest(_ path: String, org: String, header: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(org)\(path)")!)
        r.setValue(header, forHTTPHeaderField: "Cookie")
        r.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 15
        return r
    }
    static func claudeBrowser(source: BrowserSource) async throws -> UsageReading {
        QTLog.write("claudeBrowser: \(source)")
        guard let (header, org) = claudeCookieHeader(source) else { QTLog.write("claudeBrowser: header nil"); throw ProviderError.noCredential }
        QTLog.write("claudeBrowser org=\(org.prefix(8))… fetching")
        let data: Data; let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: claudeRequest("/usage?source=web", org: org, header: header)) }
        catch { QTLog.write("claudeBrowser fetch ERRO: \(error)"); throw error }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 { throw ProviderError.rateLimited(60) }
        QTLog.write("claudeBrowser HTTP \(code) bytes=\(data.count)")
        guard code == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.http(code) }
        QTLog.write("claude keys: \(Array(j.keys).prefix(12)); limits=\((j["limits"] as? [[String:Any]])?.count ?? -1)")
        return parseClaudeUsage(j)
    }

    // MARK: Antigravity — ponte LOCAL (como o Codenotch): o language server responde
    // RetrieveUserQuotaSummary em 127.0.0.1 com o csrf do processo. Token sempre vivo.
    static func shell(_ cmd: String) -> String {
        let p = Process(); p.launchPath = "/bin/sh"; p.arguments = ["-c", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    static func antigravityBridge() async throws -> UsageReading {
        let ps = shell("ps aux | grep -i language_server | grep -v grep")
        guard let csrf = ps.range(of: #"--csrf_token ([^ ]+)"#, options: .regularExpression).map({ String(ps[$0]).replacingOccurrences(of: "--csrf_token ", with: "") }) else { throw ProviderError.noCredential }
        let pid = shell("pgrep -f language_server | head -1").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else { throw ProviderError.noCredential }
        let portsOut = shell("/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -p \(pid) 2>/dev/null | awk 'NR>1{print $9}' | sed 's/.*://' | sort -u")
        let ports = portsOut.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.isEmpty }
        for port in ports {
            guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { continue }
            var req = URLRequest(url: url); req.httpMethod = "POST"
            req.setValue(csrf, forHTTPHeaderField: "x-codeium-csrf-token"); req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = "{}".data(using: .utf8); req.timeoutInterval = 6
            guard let (data, resp) = try? await insecureSession.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let response = (j["response"] as? [String: Any]) ?? j
            var daily: Double? = nil, weekly: Double? = nil
            var windows: [QuotaWindow] = []
            for g in (response["groups"] as? [[String: Any]] ?? []) {
                for b in (g["buckets"] as? [[String: Any]] ?? []) {
                    guard let rem = b["remainingFraction"] as? Double else { continue }
                    let used = 1 - rem
                    let win = (b["window"] as? String ?? "").lowercased()
                    let label = (b["displayName"] as? String) ?? win.capitalized
                    windows.append(QuotaWindow(label: label, resetText: resetText(isoDate(b["resetTime"] as? String)), fraction: used))
                    if win.contains("day") { daily = used } else if win.contains("week") { weekly = used }
                }
            }
            guard !windows.isEmpty else { continue }
            let outer = daily ?? windows.map(\.fraction).max()!
            return UsageReading(fraction: outer, inner: (daily != nil ? weekly : nil), windows: windows, fetchedAt: Date())
        }
        throw ProviderError.badResponse("Antigravity: bridge indisponível")
    }

    // MARK: Antigravity (nuvem, token do Keychain que o app do Antigravity mantém)
    static func antigravity() async throws -> UsageReading {
        // Keychain genp svce="gemini" acct="antigravity" → "go-keyring-base64:" + base64(JSON)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "gemini", kSecAttrAccount as String: "antigravity",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              var str = String(data: data, encoding: .utf8) else { throw ProviderError.noCredential }
        if str.hasPrefix("go-keyring-base64:") { str = String(str.dropFirst("go-keyring-base64:".count)) }
        guard let jd = Data(base64Encoded: str.trimmingCharacters(in: .whitespacesAndNewlines)),
              let root = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
              let tok = (root["token"] as? [String: Any])?["access_token"] as? String else { throw ProviderError.noCredential }
        var req = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 15
        let (rd, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let j = try? JSONSerialization.jsonObject(with: rd) as? [String: Any] else { throw ProviderError.http(code) }
        // schema tolerante: procura grupos com used/limit ou remaining
        var windows: [QuotaWindow] = []
        func consider(_ o: [String: Any]) {
            let name = (o["displayName"] as? String) ?? (o["name"] as? String) ?? "Quota"
            if let used = o["used"] as? Double, let limit = o["limit"] as? Double, limit > 0 {
                windows.append(QuotaWindow(label: name, resetText: resetText(isoDate(o["resetTime"] as? String)), fraction: used / limit))
            } else if let rem = o["remainingFraction"] as? Double {
                windows.append(QuotaWindow(label: name, resetText: resetText(isoDate(o["resetTime"] as? String)), fraction: 1 - rem))
            }
        }
        let response = (j["response"] as? [String: Any]) ?? j
        if let groups = response["quotaGroups"] as? [[String: Any]] {
            for g in groups { consider(g); for b in (g["buckets"] as? [[String: Any]] ?? []) { consider(b) } }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse("Antigravity: no quota") }
        return UsageReading(fraction: windows.map(\.fraction).max()!, windows: windows, fetchedAt: Date())
    }

    /// Identidade (e-mail/nome/plano) de uma conta lida de um navegador.
    static func browserIdentity(kind: ProviderKind, source: BrowserSource) async -> AccountIdentity? {
        let ck: String = { if case .chromium(let k, let p) = source { return "\(k):\(p)" }; return "safari" }()
        if let c = browserIdentityCache[ck] { return c }
        // Tudo por cookie + HTTP em segundo plano — nada abre na tela.
        switch kind {
        case .claude:
            let id = claudeBrowserIdentity(source: source)
            if let id { browserIdentityCache[ck] = id }
            return id
        case .cursor:
            // e-mail do Cursor vem do próprio usage-summary quando presente.
            guard let full = BrowserCookies.cookies(host: "cursor.com", source: source)["WorkosCursorSessionToken"] else { return nil }
            var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
            req.setValue("WorkosCursorSessionToken=\(full)", forHTTPHeaderField: "Cookie"); req.timeoutInterval = 15
            guard let (d, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            let id = AccountIdentity(email: j["email"] as? String, name: nil, plan: (j["membershipType"] as? String)?.capitalized)
            browserIdentityCache[ck] = id
            return id
        case .flow:
            let id = flowIdentity()
            if let id { browserIdentityCache[ck] = id }
            return id
        default: return nil
        }
    }

    /// Parser único de /usage do Claude (usado pelo webview e pelo Keychain).
    /// Anel de fora = janela de 5h (sessão); anel de dentro = semanal.
    static func parseClaudeUsage(_ j: [String: Any]) -> UsageReading {
        let labels = ["five_hour":"Current session","session":"Current session","seven_day":"All models","weekly_all":"All models","weekly_scoped":"Opus","seven_day_opus":"Opus","seven_day_sonnet":"Sonnet"]
        var windows: [QuotaWindow] = []
        var byKind: [String: Double] = [:]
        if let limits = j["limits"] as? [[String: Any]] {
            for l in limits {
                guard let k = l["kind"] as? String, let p = l["percent"] as? Double else { continue }
                byKind[k] = p/100
                windows.append(QuotaWindow(label: labels[k] ?? k.replacingOccurrences(of:"_",with:" ").capitalized,
                                           resetText: resetText(isoDate(l["resets_at"] as? String)), fraction: p/100))
            }
        }
        if windows.isEmpty {
            for (k,n) in [("five_hour","Current session"),("seven_day","All models"),("seven_day_opus","Opus"),("seven_day_sonnet","Sonnet")] {
                guard let b = j[k] as? [String:Any], let u = b["utilization"] as? Double else { continue }
                byKind[k] = u/100
                windows.append(QuotaWindow(label:n, resetText: resetText(isoDate(b["resets_at"] as? String)), fraction:u/100))
            }
        }
        let sessionJ = (j["five_hour"] as? [String: Any])?["utilization"] as? Double
        let weeklyJ  = (j["seven_day"] as? [String: Any])?["utilization"] as? Double
        let outer = byKind["session"] ?? byKind["five_hour"] ?? sessionJ.map { $0/100 } ?? windows.map(\.fraction).max() ?? 0
        let inner = byKind["weekly_all"] ?? byKind["seven_day"] ?? weeklyJ.map { $0/100 }
        return UsageReading(fraction: outer, inner: inner, windows: windows, fetchedAt: Date())
    }

    // MARK: Flow — via Safari (sessão viva do usuário). Pega o access_token de
    // labs.google/fx/api/auth/session (AppleScript) e lê /v1/credits com Referer.
    // Token cacheado até expirar → o Safari só é tocado ~1x/hora.
    private static var flowToken: (token: String, email: String?, name: String?, exp: Date)?
    static func flowSafari() async throws -> UsageReading {
        let tok = try await flowAccessToken()
        var req = URLRequest(url: URL(string: "https://aisandbox-pa.googleapis.com/v1/credits")!)
        req.setValue("Bearer \(tok.token)", forHTTPHeaderField: "Authorization")
        req.setValue("https://labs.google/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 12
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = (j["credits"] as? Double) else { throw ProviderError.badResponse("Flow credits") }
        let total = (j["subscriptionCredits"] as? Double) ?? max(credits, 1)
        let used = total > 0 ? max(0, (total - credits) / total) : 0
        let w = QuotaWindow(label: "\(Int(credits)) credits left", resetText: "", fraction: used)
        return UsageReading(fraction: used, windows: [w], fetchedAt: Date())
    }
    static func flowIdentity() -> AccountIdentity? {
        guard let t = try? flowAccessTokenSync() else { return nil }
        return AccountIdentity(email: t.email, name: t.name, plan: "Flow")
    }
    /// Token do Flow lido dos COOKIES do Safari (labs.google) via URLSession — não abre o Safari.
    /// Requer Full Disk Access (o Safari guarda os cookies num container protegido pelo macOS).
    private static func flowAccessToken() async throws -> (token: String, email: String?, name: String?, exp: Date) {
        if let c = flowToken, c.exp > Date().addingTimeInterval(60) { return c }
        let cookies = BrowserCookies.cookies(host: "labs.google", source: .safari)
        guard !cookies.isEmpty else {
            throw ProviderError.badResponse(BrowserAccess.hasFullDiskAccess() ? "Flow: entre no labs.google pelo Safari" : "Flow: precisa de Acesso Total ao Disco")
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        var req = URLRequest(url: URL(string: "https://labs.google/fx/api/auth/session")!)
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tok = j["access_token"] as? String, !tok.isEmpty else { throw ProviderError.badResponse("Flow: sessão expirada no Safari") }
        let user = j["user"] as? [String: Any]
        let exp = (j["expires"] as? String).flatMap { isoDate($0) } ?? Date().addingTimeInterval(3000)
        let c = (token: tok, email: user?["email"] as? String, name: user?["name"] as? String, exp: exp)
        flowToken = c
        return c
    }
    /// Versão síncrona (para identidade), reaproveita o cache e faz a leitura de cookie bloqueante.
    private static func flowAccessTokenSync() throws -> (token: String, email: String?, name: String?, exp: Date) {
        if let c = flowToken, c.exp > Date().addingTimeInterval(60) { return c }
        let sem = DispatchSemaphore(value: 0)
        var result: (token: String, email: String?, name: String?, exp: Date)?
        Task { result = try? await flowAccessToken(); sem.signal() }
        _ = sem.wait(timeout: .now() + 14)
        guard let r = result else { throw ProviderError.badResponse("Flow: token indisponível") }
        return r
    }
    /// Shell com argumentos (para osascript).
    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.launchPath = path; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    static var browserIdentityCache: [String: AccountIdentity] = [:]
    static func parseCursorUsage(_ j: [String: Any]) -> UsageReading {
        let iu = j["individualUsage"] as? [String: Any]; let plan = iu?["plan"] as? [String: Any]
        let end = isoDate(j["billingCycleEnd"] as? String)
        let reset = resetText(end)
        func num(_ k: String) -> Double? { (plan?[k] as? NSNumber)?.doubleValue }
        // Dois buckets reais do Cursor: "Cursor Models" (auto) e "Other Models" (API).
        let auto = num("autoPercentUsed")
        let api  = num("apiPercentUsed")
        var windows: [QuotaWindow] = []
        var outer: Double
        var inner: Double? = nil
        if let auto {
            outer = auto / 100
            windows.append(QuotaWindow(label: "Cursor Models", resetText: reset, fraction: outer))
            if let api {
                inner = api / 100
                windows.append(QuotaWindow(label: "Other Models", resetText: reset, fraction: inner!))
            }
        } else {
            // Fallback: totalPercentUsed, ou mensagem, ou used/limit.
            var pct = num("totalPercentUsed")
            if pct == nil, let msg = j["autoModelSelectedDisplayMessage"] as? String,
               let m = msg.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) { pct = Double(msg[m].dropLast()) }
            if pct == nil, let u = num("used"), let l = num("limit"), l > 0 { pct = u / l * 100 }
            outer = (pct ?? 0) / 100
            windows.append(QuotaWindow(label: "Included usage", resetText: reset, fraction: outer))
        }
        // On-demand como janela extra no hover (não vira anel).
        if let od = iu?["onDemand"] as? [String: Any], (od["enabled"] as? Bool) == true,
           let used = (od["used"] as? NSNumber)?.doubleValue, let limit = (od["limit"] as? NSNumber)?.doubleValue, limit > 0 {
            windows.append(QuotaWindow(label: "On demand", resetText: reset, fraction: used / limit))
        }
        return UsageReading(fraction: outer, inner: inner, windows: windows, fetchedAt: Date())
    }

    // MARK: util
    static func resetText(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = d.timeIntervalSinceNow
        if s <= 0 { return "Resetting…" }
        if s < 86_400 {
            let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
            return h > 0 ? "Resets in \(h) hr \(m) min" : "Resets in \(m) min"
        }
        let f = DateFormatter(); f.dateFormat = "E h:mm a"
        return "Resets " + f.string(from: d)
    }
}

/// Agenda as leituras: no launch, a cada 300 s, ao acordar e no clique.
@MainActor
final class RefreshCoordinator {
    /// Última leitura por automação NESTA execução (não vem do cache em disco).
    static var lastAutomationRead: [UUID: Date] = [:]

    private let model: NotchModel
    private let store: ConfigStore
    private var timer: Timer?
    private var inFlight: Set<UUID> = []

    private var retryNotBefore: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]
    private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quotch/lastGoodReadings.json")

    init(model: NotchModel, store: ConfigStore) {
        self.model = model; self.store = store
        restoreCache()
        timer = Timer.scheduledTimer(withTimeInterval: Providers.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        timer?.tolerance = 30
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshAll() }
        NotificationCenter.default.addObserver(forName: .quotchRefresh, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    /// Só a conta "viva" (a primeira de cada provedor) tem credencial legível hoje.
    func refreshAll() {
        let vault = Vault.load()
        var seen = Set<ProviderKind>()
        for slot in model.slots {
            QTLog.write("refreshAll slot \(slot.kind) cp=\(slot.chromeProfile ?? "nil")")
            // Tudo é leitura HTTP em segundo plano agora — sem abrir aba, roda no ciclo normal.
            if slot.chromeProfile != nil || slot.kind == .flow { refresh(slot); continue }   // navegador/web/flow: sempre
            if vault[slot.id] != nil { refresh(slot); continue }
            if !seen.contains(slot.kind) { seen.insert(slot.kind); refresh(slot) }
        }
    }

    /// Pinta a última leitura boa no launch, antes de qualquer rede (como o the reference notch app).
    private func restoreCache() {
        guard let d = try? Data(contentsOf: Self.cacheURL),
              let all = try? JSONDecoder().decode([UUID: StoredReading].self, from: d) else { return }
        for (id, r) in all {
            let reading = UsageReading(fraction: r.fraction, windows: r.windows.map { QuotaWindow(label: $0.label, resetText: $0.resetText, fraction: $0.fraction) }, fetchedAt: r.fetchedAt)
            model.readings[id] = reading
            let stale = Date().timeIntervalSince(r.fetchedAt) > Providers.interval
            model.setState(id, stale ? .stale(fraction: r.fraction) : .reading(fraction: r.fraction))
        }
    }
    private func persistCache() {
        var all: [UUID: StoredReading] = [:]
        for (id, r) in model.readings {
            all[id] = StoredReading(fraction: r.fraction, windows: r.windows.map { StoredWindow(label: $0.label, resetText: $0.resetText, fraction: $0.fraction) }, fetchedAt: r.fetchedAt)
        }
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: Self.cacheURL, options: [.atomic]) }
    }

    func refresh(_ slot: AccountSlot) {
        guard !inFlight.contains(slot.id) else { return }
        if let t = retryNotBefore[slot.id], t > Date() { return }   // backoff em curso
        inFlight.insert(slot.id)
        let allow = store.config.readClaudeKeychain
        Task {
            defer { inFlight.remove(slot.id) }
            do {
                let r: UsageReading
                if slot.kind == .flow {
                    r = try await Providers.flowSafari()
                } else if slot.chromeProfile == "web" {
                    r = try await WebSession.shared.read(accountID: slot.id, kind: slot.kind)
                } else if let src = BrowserSource.parse(slot.chromeProfile) {
                    // Navegador do usuário, já logado: lê o COOKIE de sessão e chama a API
                    // por HTTP em segundo plano. Nada abre na tela (Safari exige Acesso Total ao Disco).
                    switch slot.kind {
                    case .cursor: r = try await Providers.cursorBrowser(source: src)
                    case .grok:   r = try await Providers.grokBrowser(source: src)
                    default:      r = try await Providers.claudeBrowser(source: src)
                    }
                } else {
                    let vaulted = Vault.load()[slot.id]
                    r = try await Providers.fetch(slot.kind, allowKeychain: allow, vaulted: vaulted)
                }
                if slot.chromeProfile == nil, Vault.load()[slot.id] != nil, slot.kind != .codex { Vault.storeReading(r, for: slot.id) }
                model.readings[slot.id] = r
                // Nome/e-mail em segundo plano (uma vez por conta de navegador).
                if let src = BrowserSource.parse(slot.chromeProfile),
                   ConfigStore.shared.config.notchOrder.first(where: { $0.id == slot.id })?.email == nil,
                   let ident = await Providers.browserIdentity(kind: slot.kind, source: src) {
                    ConfigStore.shared.setIdentity(slot.id, ident)
                }
                withAnimation(NQMotion.value) { model.setState(slot.id, .reading(fraction: r.fraction, weekly: r.inner)) }
                model.refreshToken[slot.id, default: 0] += 1
                failures[slot.id] = 0; retryNotBefore[slot.id] = nil
                persistCache()
                QTLog.write("refresh \(slot.kind): \(Int(r.fraction * 100))% windows=\(r.windows.count)")
            } catch ProviderError.rateLimited(let after) {
                // Respeita Retry-After; teto de 900 s como o original.
                retryNotBefore[slot.id] = Date().addingTimeInterval(min(max(after, 60), 900))
                QTLog.write("refresh \(slot.kind): 429, tenta em \(Int(min(max(after, 60), 900))) s")
            } catch ProviderError.noCredential {
                QTLog.write("refresh \(slot.kind): sem credencial (mantém o estado)")
            } catch {
                QTLog.write("refresh \(slot.kind) falhou: \(error)")
                let n = (failures[slot.id] ?? 0) + 1; failures[slot.id] = n
                retryNotBefore[slot.id] = Date().addingTimeInterval(min(pow(2, Double(min(n, 4))) * 60, 900))   // 2^n·60, teto 900
                if case .reading(let f, _) = slot.state { model.setState(slot.id, .stale(fraction: f)) }
            }
        }
    }
}

extension Notification.Name {
    static let quotchRefresh = Notification.Name("quotch.refresh")
    static let quotchReconcile = Notification.Name("quotch.reconcile")
}
