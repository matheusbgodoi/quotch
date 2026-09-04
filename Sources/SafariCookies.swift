import Foundation

/// Lê o Cookies.binarycookies do Safari (precisa de Full Disk Access no app).
/// Formato: magic "cook", páginas com cookies (url,name,value...).
enum SafariCookies {
    static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies").path
    }
    static var readable: Bool { FileManager.default.isReadableFile(atPath: path) && (try? Data(contentsOf: URL(fileURLWithPath: path)).prefix(4)) == Data("cook".utf8) }

    static func cookies(host: String) -> [String: String] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), d.count > 12, d.prefix(4) == Data("cook".utf8) else { return [:] }
        let n = d.count
        // Leitura com verificação de limites — nunca acessa fora do buffer.
        func u32be(_ o: Int) -> Int? { guard o >= 0, o+4 <= n else { return nil }; return Int(d[d.startIndex+o])<<24 | Int(d[d.startIndex+o+1])<<16 | Int(d[d.startIndex+o+2])<<8 | Int(d[d.startIndex+o+3]) }
        func u32le(_ o: Int) -> Int? { guard o >= 0, o+4 <= n else { return nil }; return Int(d[d.startIndex+o]) | Int(d[d.startIndex+o+1])<<8 | Int(d[d.startIndex+o+2])<<16 | Int(d[d.startIndex+o+3])<<24 }
        func cstr(_ start: Int) -> String {
            guard start >= 0, start < n else { return "" }
            var e = start; let base = d.startIndex
            while e < n && d[base+e] != 0 { e += 1 }
            return String(data: d[(base+start)..<(base+e)], encoding: .utf8) ?? ""
        }
        guard let nPages = u32be(4), nPages >= 0, nPages < 100_000 else { return [:] }
        var sizes: [Int] = []
        for i in 0..<nPages { guard let s = u32be(8 + i*4), s > 8 else { return [:] }; sizes.append(s) }
        var out: [String: String] = [:]
        var pos = 8 + nPages*4              // dados das páginas começam logo após a tabela de tamanhos
        for size in sizes {
            let pageStart = pos
            defer { pos = pageStart + size }
            guard pageStart + 8 <= n, let nc = u32le(pageStart+4), nc >= 0, nc < 100_000 else { continue }
            for i in 0..<nc {
                guard let rel = u32le(pageStart + 8 + i*4) else { break }
                let co = pageStart + rel                       // offset do cookie é relativo ao início da página
                guard co >= 0, co + 32 <= n,
                      let urlR = u32le(co+16), let nameR = u32le(co+20), let valR = u32le(co+28) else { continue }
                let dom = cstr(co + urlR)
                if dom == host || dom == "."+host || dom.hasSuffix("."+host) {
                    let name = cstr(co + nameR)
                    if !name.isEmpty { out[name] = cstr(co + valR) }
                }
            }
        }
        return out
    }
}

/// Fonte de leitura de uma conta de navegador.
enum BrowserSource {
    case safari
    case chromium(browserKey: String, profile: String)
    /// Formato salvo: "safari" | "<browserKey>:<profileDir>" (perfil pode ter espaços).
    static func parse(_ s: String?) -> BrowserSource? {
        guard let s else { return nil }
        if s == "safari" { return .safari }
        guard let i = s.firstIndex(of: ":") else { return nil }
        let key = String(s[s.startIndex..<i]); let prof = String(s[s.index(after: i)...])
        return .chromium(browserKey: key, profile: prof)
    }
}

enum BrowserCookies {
    static func cookies(host: String, source: BrowserSource) -> [String: String] {
        switch source {
        case .safari: return SafariCookies.cookies(host: host)
        case .chromium(let key, let profile):
            guard let b = ChromiumCookies.browser(key) else { QTLog.write("BrowserCookies: browser(\(key)) nil"); return [:] }
            return ChromiumCookies.cookies(host: host, browser: b, profile: profile)
        }
    }
}

extension ProviderKind {
    /// Cookie que indica sessão logada daquele serviço no navegador.
    var sessionCookie: (host: String, name: String)? {
        switch self {
        case .claude: return ("claude.ai", "sessionKey")
        case .cursor: return ("cursor.com", "WorkosCursorSessionToken")
        default: return nil
        }
    }
}
