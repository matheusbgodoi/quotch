import Foundation
import CommonCrypto
import SQLite3

/// Lê cookies de qualquer navegador Chromium instalado (Chrome, Brave, Edge, Arc,
/// Vivaldi, Chromium…), por perfil. macOS v10: AES-128-CBC, IV=16×0x20,
/// chave=PBKDF2-SHA1(<Browser> Safe Storage, "saltysalt", 1003, 16) do Keychain.
enum ChromiumCookies {
    struct Browser: Identifiable, Equatable {
        let key: String        // "chrome", "brave"…
        let name: String       // "Chrome"
        let dir: String        // sob ~/Library/Application Support
        let service: String    // item do Keychain
        var id: String { key }
    }
    struct Profile: Identifiable, Equatable { let dir: String; let name: String; var id: String { dir } }

    static let known: [Browser] = [
        .init(key: "chrome",   name: "Chrome",   dir: "Google/Chrome",                  service: "Chrome Safe Storage"),
        .init(key: "brave",    name: "Brave",    dir: "BraveSoftware/Brave-Browser",    service: "Brave Safe Storage"),
        .init(key: "edge",     name: "Edge",     dir: "Microsoft Edge",                 service: "Microsoft Edge Safe Storage"),
        .init(key: "arc",      name: "Arc",      dir: "Arc/User Data",                  service: "Arc Safe Storage"),
        .init(key: "vivaldi",  name: "Vivaldi",  dir: "Vivaldi",                        service: "Vivaldi Safe Storage"),
        .init(key: "chromium", name: "Chromium", dir: "Chromium",                       service: "Chromium Safe Storage"),
    ]
    private static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support") }
    static func browser(_ key: String) -> Browser? { known.first { $0.key == key } }
    /// Navegadores realmente instalados (têm dir de dados com Local State).
    static func installed() -> [Browser] {
        known.filter { FileManager.default.fileExists(atPath: support.appendingPathComponent($0.dir + "/Local State").path) }
    }
    static func profiles(_ b: Browser) -> [Profile] {
        let ls = support.appendingPathComponent(b.dir + "/Local State")
        guard let data = try? Data(contentsOf: ls),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (j["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [.init(dir: "Default", name: "Default")] }
        return cache.map { Profile(dir: $0.key, name: ($0.value as? [String: Any])?["name"] as? String ?? $0.key) }
            .sorted { ($0.dir == "Default" ? "" : $0.dir) < ($1.dir == "Default" ? "" : $1.dir) }
    }

    private static var keyCache: [String: Data] = [:]
    private static func aesKey(service: String) -> Data? {
        if let k = keyCache[service] { return k }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let rc = SecItemCopyMatching(q as CFDictionary, &out)
        guard rc == errSecSuccess, let pw = out as? Data else { QTLog.write("aesKey(\(service)): rc=\(rc)"); return nil }
        var key = Data(count: 16); let salt = Array("saltysalt".utf8)
        let ok = key.withUnsafeMutableBytes { kb in pw.withUnsafeBytes { pb in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pb.baseAddress, pb.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, kb.baseAddress, 16) } }
        guard ok == kCCSuccess else { return nil }
        QTLog.write("aesKey(\(service)): OK"); keyCache[service] = key; return key
    }

    /// Existe um cookie <name> para <host> neste perfil? (sem Keychain, só texto)
    static func hasCookie(host: String, name: String, browser b: Browser, profile: String) -> Bool {
        let base = support.appendingPathComponent(b.dir).appendingPathComponent(profile)
        let cands = [base.appendingPathComponent("Network/Cookies").path, base.appendingPathComponent("Cookies").path]
        guard let db = cands.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qh-\(UUID().uuidString).sqlite").path
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + s) }
        guard (try? FileManager.default.copyItem(atPath: db, toPath: tmp)) != nil else { return false }
        for s in ["-wal","-shm"] where FileManager.default.fileExists(atPath: db+s) { try? FileManager.default.copyItem(atPath: db+s, toPath: tmp+s) }
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + s) } }
        var h: OpaquePointer?; guard sqlite3_open_v2(tmp, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let h else { return false }
        defer { sqlite3_close(h) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "SELECT 1 FROM cookies WHERE name = ? AND (host_key = ? OR host_key = ?) LIMIT 1", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(st, 1, name, -1, T); sqlite3_bind_text(st, 2, host, -1, T); sqlite3_bind_text(st, 3, "."+host, -1, T)
        return sqlite3_step(st) == SQLITE_ROW
    }

    static func cookies(host: String, browser b: Browser, profile: String) -> [String: String] {
        guard let key = aesKey(service: b.service) else { return [:] }
        let base = support.appendingPathComponent(b.dir).appendingPathComponent(profile)
        let candidates = [base.appendingPathComponent("Network/Cookies").path, base.appendingPathComponent("Cookies").path]
        guard let db = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            QTLog.write("cookies(\(host)/\(b.key):\(profile)): sem arquivo Cookies"); return [:] }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qk-\(UUID().uuidString).sqlite").path
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + s) }
        do { try FileManager.default.copyItem(atPath: db, toPath: tmp) } catch { QTLog.write("cookies copy FAIL: \(error)"); return [:] }
        for s in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: db + s) { try? FileManager.default.copyItem(atPath: db + s, toPath: tmp + s) }
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp + s) } }
        var h: OpaquePointer?
        let orc = sqlite3_open_v2(tmp, &h, SQLITE_OPEN_READWRITE, nil); guard orc == SQLITE_OK, let h else { QTLog.write("cookies open rc=\(orc)"); return [:] }
        defer { sqlite3_close(h) }
        var st: OpaquePointer?
        let prc = sqlite3_prepare_v2(h, "SELECT name, encrypted_value FROM cookies WHERE host_key = ? OR host_key = ?", -1, &st, nil); guard prc == SQLITE_OK else { QTLog.write("cookies prepare rc=\(prc): \(String(cString: sqlite3_errmsg(h)))"); return [:] }
        defer { sqlite3_finalize(st) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(st, 1, host, -1, T); sqlite3_bind_text(st, 2, "." + host, -1, T)
        var out: [String: String] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            guard let np = sqlite3_column_text(st, 0) else { continue }
            let name = String(cString: np); let n = Int(sqlite3_column_bytes(st, 1))
            guard n > 3, let bp = sqlite3_column_blob(st, 1) else { continue }
            let enc = Data(bytes: bp, count: n)
            guard enc.prefix(3) == Data("v10".utf8), let dec = decrypt(enc.dropFirst(3), key: key) else { continue }
            out[name] = dec
        }
        QTLog.write("cookies(\(host)/\(b.key):\(profile)): \(out.count) itens; sessionKey=\(out["sessionKey"] != nil)")
        return out
    }

    private static func decrypt(_ body: Data, key: Data) -> String? {
        let iv = [UInt8](repeating: 0x20, count: 16); var outLen = 0
        var buf = Data(count: body.count + kCCBlockSizeAES128)
        let status = buf.withUnsafeMutableBytes { ob in body.withUnsafeBytes { ib in key.withUnsafeBytes { kb in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    kb.baseAddress, 16, iv, ib.baseAddress, ib.count, ob.baseAddress, ob.count, &outLen) } } }
        guard status == kCCSuccess else { return nil }
        buf.removeSubrange(outLen..<buf.count)
        if buf.count > 32, !buf.prefix(8).allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) { buf.removeFirst(32) }
        return String(data: buf, encoding: .utf8)
    }

    /// Descriptografa um valor salvo pelo `safeStorage` do Electron no macOS.
    /// O formato é o mesmo `v10` usado pelos cookies Chromium. É usado pelo
    /// Grok Bot para manter o token de sessão no arquivo `sand-secrets.json`.
    static func decryptSafeStorage(_ encoded: String, service: String) -> String? {
        guard let encrypted = Data(base64Encoded: encoded),
              encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              let key = aesKey(service: service) else { return nil }
        return decrypt(Data(encrypted.dropFirst(3)), key: key)
    }
}

/// Compat: chamadas antigas por "perfil do Chrome".
enum ChromeCookies {
    struct Profile: Identifiable, Equatable { let dir: String; let name: String; var id: String { dir } }
    static func profiles() -> [Profile] {
        (ChromiumCookies.browser("chrome").map { ChromiumCookies.profiles($0) } ?? []).map { .init(dir: $0.dir, name: $0.name) }
    }
    static func cookies(host: String, profile: String) -> [String: String] {
        guard let b = ChromiumCookies.browser("chrome") else { return [:] }
        return ChromiumCookies.cookies(host: host, browser: b, profile: profile)
    }
}
