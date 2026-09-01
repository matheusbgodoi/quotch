import Foundation
import SQLite3

/// Identidade da conta (e-mail, nome, plano) lida das ferramentas donas SEM tocar
/// em token: ~/.claude.json, claims do id_token do Codex, cachedEmail do Cursor.
struct AccountIdentity: Equatable {
    var email: String?
    var name: String?
    var plan: String?
}

enum IdentityProbe {
    static func probe(_ kind: ProviderKind) -> AccountIdentity? {
        switch kind {
        case .claude: return claude()
        case .codex: return codex()
        case .cursor: return cursor()
        case .antigravity: return antigravity()
        case .flow: return nil
        }
    }

    static func claude() -> AccountIdentity? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oa = root["oauthAccount"] as? [String: Any] else { return nil }
        // "default_claude_max_5x" -> "Max 5×"; "…pro…" -> "Pro"; senão o seatTier cru.
        let tier = (oa["userRateLimitTier"] as? String) ?? (oa["organizationRateLimitTier"] as? String) ?? ""
        let plan: String? = {
            if let m = tier.range(of: #"max_(\d+)x"#, options: .regularExpression) {
                let n = tier[m].filter { $0.isNumber }; return "Max \(n)×"
            }
            if tier.contains("pro") { return "Pro" }
            if tier.contains("free") { return "Free" }
            return (oa["seatTier"] as? String).map { $0.capitalized }
        }()
        return AccountIdentity(email: oa["emailAddress"] as? String,
                               name: (oa["displayName"] as? String) ?? (oa["fullName"] as? String),
                               plan: plan)
    }

    static func codex() -> AccountIdentity? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idt = tokens["id_token"] as? String else { return nil }
        let parts = idt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let pd = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] else { return nil }
        let ns = claims["https://api.openai.com/auth"] as? [String: Any]
        let plan = (ns?["chatgpt_plan_type"] as? String).map { $0.capitalized }
        return AccountIdentity(email: claims["email"] as? String, name: claims["name"] as? String, plan: plan)
    }

    static func cursor() -> AccountIdentity? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Sempre uma CÓPIA, em modo leitura: nunca o arquivo vivo do editor.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quotch-cursor-\(getpid()).vscdb").path
        for suf in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + suf) }
        guard (try? FileManager.default.copyItem(atPath: path, toPath: tmp)) != nil else { return nil }
        for suf in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suf) {
            try? FileManager.default.copyItem(atPath: path + suf, toPath: tmp + suf)
        }
        defer { for suf in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + suf) } }
        var db: OpaquePointer?
        // A base está em modo WAL: read-only puro dá SQLITE_CANTOPEN (14). A cópia é
        // nossa, então abrir com escrita é seguro — o arquivo vivo nunca é tocado.
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        func value(_ key: String) -> String? {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &st, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_text(st, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
            return String(cString: c)
        }
        return AccountIdentity(email: value("cursorAuth/cachedEmail"), name: nil,
                               plan: value("cursorAuth/stripeMembershipType").map { $0.capitalized })
    }

    static func antigravity() -> AccountIdentity? {
        // Estado local do Antigravity (~/.gemini/antigravity): procura um e-mail em texto.
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity")
        for name in ["antigravity_state.pbtxt", "config.json", "settings.json"] {
            let u = dir.appendingPathComponent(name)
            guard let s = try? String(contentsOf: u, encoding: .utf8), s.count < 2_000_000 else { continue }
            if let r = s.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) {
                return AccountIdentity(email: String(s[r]), name: nil, plan: nil)
            }
        }
        return nil
    }
}
