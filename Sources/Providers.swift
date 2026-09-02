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
        }
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
        let iu = j["individualUsage"] as? [String: Any]; let plan = iu?["plan"] as? [String: Any]
        let pct = (plan?["totalPercentUsed"] as? Double) ?? 0
        return UsageReading(fraction: pct/100, windows: [QuotaWindow(label:"Included usage", resetText:"", fraction: pct/100)], fetchedAt: Date())
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
        if kind == .claude {
            if case .chromium(_, let p) = source { _ = try? await claudeChrome(profileDir: p) } else { _ = try? await claudeSafari() }
            if let c = browserIdentityCache[ck] { return c }
        }
        switch kind {
        case .claude: return claudeBrowserIdentity(source: source)
        case .cursor:
            // e-mail do Cursor vem do próprio usage-summary quando presente.
            guard let full = BrowserCookies.cookies(host: "cursor.com", source: source)["WorkosCursorSessionToken"] else { return nil }
            var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
            req.setValue("WorkosCursorSessionToken=\(full)", forHTTPHeaderField: "Cookie"); req.timeoutInterval = 15
            guard let (d, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return AccountIdentity(email: j["email"] as? String, name: nil, plan: (j["membershipType"] as? String)?.capitalized)
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
        let tok = try flowAccessToken()
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
        guard let t = try? flowAccessToken() else { return nil }
        return AccountIdentity(email: t.email, name: t.name, plan: "Flow")
    }
    private static func flowAccessToken() throws -> (token: String, email: String?, name: String?, exp: Date) {
        if let c = flowToken, c.exp > Date().addingTimeInterval(60) { return c }
        let out = safariJS(url: "https://labs.google/fx/api/auth/session", js: "window.__qt=document.body.innerText;'x'", settle: 4)
        guard let d = out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tok = j["access_token"] as? String, !tok.isEmpty else { throw ProviderError.badResponse("Flow: entre no Safari") }
        let user = j["user"] as? [String: Any]
        let exp = (j["expires"] as? String).flatMap { isoDate($0) } ?? Date().addingTimeInterval(3000)
        let c = (token: tok, email: user?["email"] as? String, name: user?["name"] as? String, exp: exp)
        flowToken = c
        return c
    }
    /// Shell com argumentos (para osascript).
    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.launchPath = path; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: Automação do NAVEGADOR do usuário (já logado) — como o Flow via Safari.
    // Chrome: abre a URL num PERFIL específico (--profile-directory), acha a aba por nonce,
    // roda JS via Apple Events (precisa de "Permitir JavaScript de Eventos da Apple" no Chrome).
    // Safari: "Permitir JavaScript de Eventos da Apple" no menu Desenvolvedor.
    static let claudeUsageJS = "window.__qt='PENDING';(async()=>{try{let org=(document.cookie.match(/lastActiveOrg=([^;]+)/)||[])[1];const H={headers:{'anthropic-client-platform':'web_claude_ai'}};if(!org){const o=await (await fetch('/api/organizations',H)).json();org=o&&o[0]&&(o[0].uuid||o[0].id);}if(!org){window.__qt='NOORG';return;}const r=await fetch('/api/organizations/'+org+'/usage?source=web',H);if(r.status!==200){window.__qt='HTTP'+r.status;return;}const j=await r.json();try{const b=await (await fetch('/api/bootstrap',H)).json();const a=b.account||{};j.__email=a.email_address||a.email||null;j.__name=a.full_name||null;}catch(e){}window.__qt=JSON.stringify(j);}catch(e){window.__qt='ERR '+e}})();'started'"
    static var browserIdentityCache: [String: AccountIdentity] = [:]
    /// Uma automação de navegador por vez (Safari/Chrome): evita duas abas disputando "front document".
    static let automationLock = NSLock()

    private static func tmpWrite(_ text: String, _ ext: String) -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("quotch-\(UUID().uuidString).\(ext)").path
        try? text.write(toFile: p, atomically: true, encoding: .utf8); return p
    }
    /// Roda JS numa aba nova do Chrome no perfil dado; o JS deve escrever window.__qt ao terminar.
    static func chromeJS(profile: String, url: String, js: String) -> String {
        automationLock.lock(); defer { automationLock.unlock() }
        let nonce = "qt-" + String(UUID().uuidString.prefix(8)).lowercased()
        let p = Process(); p.launchPath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        p.arguments = ["--profile-directory=\(profile)", url + "#" + nonce]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        Thread.sleep(forTimeInterval: 7)
        let jsPath = tmpWrite(js, "js")
        let script = """
        set js to (read POSIX file "\(jsPath)" as «class utf8»)
        tell application "Google Chrome"
          set target to missing value
          repeat with w in windows
            repeat with t in tabs of w
              if URL of t contains "\(nonce)" then set target to t
            end repeat
          end repeat
          if target is missing value then return "NO_TAB"
          try
            execute target javascript js
          on error e
            close target
            return "JS_ERR: " & e
          end try
          repeat 25 times
            delay 1
            set v to execute target javascript "window.__qt"
            if v is not "PENDING" then
              close target
              return v
            end if
          end repeat
          close target
          return "TIMEOUT"
        end tell
        """
        let asPath = tmpWrite(script, "applescript")
        defer { try? FileManager.default.removeItem(atPath: jsPath); try? FileManager.default.removeItem(atPath: asPath) }
        return shell("/usr/bin/osascript", [asPath]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Roda JS numa aba nova do Safari; o JS deve escrever window.__qt.
    static func safariJS(url: String, js: String, settle: Double = 6) -> String {
        automationLock.lock(); defer { automationLock.unlock() }
        let nonce = "qt-" + String(UUID().uuidString.prefix(8)).lowercased()
        let jsPath = tmpWrite(js, "js")
        let script = """
        set js to (read POSIX file "\(jsPath)" as «class utf8»)
        tell application "Safari"
          make new document with properties {URL:"\(url)#\(nonce)"}
          delay \(settle)
          set target to missing value
          repeat with w in windows
            repeat with t in tabs of w
              if URL of t contains "\(nonce)" then set target to t
            end repeat
          end repeat
          if target is missing value then return "NO_TAB"
          do JavaScript js in target
          set v to "PENDING"
          repeat 25 times
            delay 1
            set v to do JavaScript "window.__qt" in target
            if v is not "PENDING" then exit repeat
          end repeat
          close target
          return v
        end tell
        """
        let asPath = tmpWrite(script, "applescript")
        defer { try? FileManager.default.removeItem(atPath: jsPath); try? FileManager.default.removeItem(atPath: asPath) }
        return shell("/usr/bin/osascript", [asPath]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func claudeChrome(profileDir: String) async throws -> UsageReading {
        let out = chromeJS(profile: profileDir, url: "https://claude.ai/settings/usage", js: claudeUsageJS)
        return try parseClaudeAutomation(out, cacheKey: "chrome:\(profileDir)")
    }
    static func claudeSafari() async throws -> UsageReading {
        let out = safariJS(url: "https://claude.ai/settings/usage", js: claudeUsageJS)
        return try parseClaudeAutomation(out, cacheKey: "safari")
    }
    private static func parseClaudeAutomation(_ out: String, cacheKey: String) throws -> UsageReading {
        QTLog.write("claude browser[\(cacheKey)]: \(out.prefix(70))")
        guard out.hasPrefix("{"), let d = out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw ProviderError.badResponse("Claude browser: \(out.prefix(90))")
        }
        if let e = j["__email"] as? String {
            browserIdentityCache[cacheKey] = AccountIdentity(email: e, name: j["__name"] as? String, plan: nil)
        }
        return parseClaudeUsage(j)
    }
    static func cursorSafari() async throws -> UsageReading {
        let out = safariJS(url: "https://cursor.com/api/usage-summary", js: "window.__qt=document.body.innerText;'x'", settle: 5)
        QTLog.write("cursor safari: \(out.prefix(60))")
        guard out.hasPrefix("{"), let d = out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw ProviderError.badResponse("Cursor safari: \(out.prefix(90))")
        }
        return parseCursorUsage(j)
    }
    static func parseCursorUsage(_ j: [String: Any]) -> UsageReading {
        let iu = j["individualUsage"] as? [String: Any]; let plan = iu?["plan"] as? [String: Any]
        var pct = (plan?["totalPercentUsed"] as? Double)
        if pct == nil, let msg = j["autoModelSelectedDisplayMessage"] as? String,
           let m = msg.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) {
            pct = Double(msg[m].dropLast())
        }
        if pct == nil, let u = plan?["used"] as? Double, let l = plan?["limit"] as? Double, l > 0 { pct = u / l * 100 }
        let frac = (pct ?? 0) / 100
        let end = isoDate(j["billingCycleEnd"] as? String)
        var windows = [QuotaWindow(label: "Included usage", resetText: resetText(end), fraction: frac)]
        if let od = iu?["onDemand"] as? [String: Any], (od["enabled"] as? Bool) == true,
           let used = od["used"] as? Double, let limit = od["limit"] as? Double, limit > 0 {
            windows.append(QuotaWindow(label: "On demand", resetText: resetText(end), fraction: used / limit))
        }
        return UsageReading(fraction: windows.map(\.fraction).max() ?? frac, windows: windows, fetchedAt: Date())
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
            // Fontes por automação de navegador abrem uma aba: no ciclo automático, no máximo a cada 15 min.
            if BrowserSource.parse(slot.chromeProfile) != nil || slot.kind == .flow,
               let last = RefreshCoordinator.lastAutomationRead[slot.id], Date().timeIntervalSince(last) < 900 { continue }
            if slot.chromeProfile != nil { refresh(slot); continue }   // navegador/web: sempre
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
                    // navegador do usuário, já logado: automação (não lê cookie de disco)
                    switch (slot.kind, src) {
                    case (.cursor, .safari):                r = try await Providers.cursorSafari()
                    case (.claude, .safari):                r = try await Providers.claudeSafari()
                    case (.claude, .chromium(_, let prof)): r = try await Providers.claudeChrome(profileDir: prof)
                    default: r = slot.kind == .cursor ? try await Providers.cursorBrowser(source: src)
                                                      : try await Providers.claudeBrowser(source: src)
                    }
                } else {
                    let vaulted = Vault.load()[slot.id]
                    r = try await Providers.fetch(slot.kind, allowKeychain: allow, vaulted: vaulted)
                }
                if slot.chromeProfile == nil, Vault.load()[slot.id] != nil, slot.kind != .codex { Vault.storeReading(r, for: slot.id) }
                model.readings[slot.id] = r
                RefreshCoordinator.lastAutomationRead[slot.id] = Date()
                if let src = slot.chromeProfile, let ident = Providers.browserIdentityCache[src.replacingOccurrences(of: "chrome:", with: "chrome:")] ?? Providers.browserIdentityCache[src == "safari" ? "safari" : src] {
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
