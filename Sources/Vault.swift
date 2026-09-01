import Foundation
import Security

/// Cofre de credenciais capturadas — o que destrava a 2ª conta real por provedor.
/// Guarda em ~/Library/Application Support/Quotch/vault.json (0600). Keychain fica
/// para quando houver assinatura Developer ID (ad-hoc muda o cdhash a cada build e
/// o macOS pediria autorização em todo rebuild).
struct StoredWindow: Codable { var label: String; var resetText: String; var fraction: Double }
struct StoredReading: Codable { var fraction: Double; var windows: [StoredWindow]; var fetchedAt: Date }

struct VaultedCredential: Codable {
    var kind: ProviderKind
    var capturedAt: Date
    var fields: [String: String]          // nunca logar
    var lastReading: StoredReading?
}

enum Vault {
    static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vault.json")
    }
    static func load() -> [UUID: VaultedCredential] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([UUID: VaultedCredential].self, from: d)) ?? [:]
    }
    static func save(_ v: [UUID: VaultedCredential]) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        try? d.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func remove(_ id: UUID) { var v = load(); v[id] = nil; save(v) }
    static func has(_ id: UUID) -> Bool { load()[id] != nil }

    /// Tira uma foto da credencial VIVA da ferramenta dona e guarda para `id`.
    static func capture(kind: ProviderKind, for id: UUID, allowKeychain: Bool) -> Bool {
        guard let fields = liveFields(kind, allowKeychain: allowKeychain) else { return false }
        var v = load()
        v[id] = VaultedCredential(kind: kind, capturedAt: Date(), fields: fields, lastReading: nil)
        save(v)
        return true
    }

    static func storeReading(_ r: UsageReading, for id: UUID) {
        var v = load(); guard v[id] != nil else { return }
        v[id]!.lastReading = StoredReading(fraction: r.fraction,
            windows: r.windows.map { StoredWindow(label: $0.label, resetText: $0.resetText, fraction: $0.fraction) },
            fetchedAt: r.fetchedAt)
        save(v)
    }

    private static func liveFields(_ kind: ProviderKind, allowKeychain: Bool) -> [String: String]? {
        switch kind {
        case .cursor:
            guard let a = Providers.cursorItem("cursorAuth/stripeMembershipAuthId"),
                  let t = Providers.cursorItem("cursorAuth/accessToken") else { return nil }
            return ["authId": a, "accessToken": t]
        case .claude:
            guard allowKeychain, let j = Providers.claudeKeychainJSON(),
                  let oauth = j["claudeAiOauth"] as? [String: Any],
                  let t = oauth["accessToken"] as? String else { return nil }
            var f = ["accessToken": t]
            if let e = oauth["expiresAt"] as? Double { f["expiresAt"] = String(e) }
            return f
        case .codex:
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
            guard let d = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let tokens = root["tokens"] as? [String: Any],
                  let acc = tokens["account_id"] as? String else { return nil }
            return ["accountId": acc]
        case .antigravity, .flow: return nil
        }
    }
}
