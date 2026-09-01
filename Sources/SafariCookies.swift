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
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), d.count > 8, d.prefix(4) == Data("cook".utf8) else { return [:] }
        func u32be(_ o: Int) -> Int { Int(d[o])<<24 | Int(d[o+1])<<16 | Int(d[o+2])<<8 | Int(d[o+3]) }
        func u32le(_ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o+1])<<8 | UInt32(d[o+2])<<16 | UInt32(d[o+3])<<24 }
        let nPages = u32be(4)
        var pageOffsets: [Int] = []; var p = 8
        for _ in 0..<nPages { pageOffsets.append(u32be(p)); p += 4 }
        var out: [String: String] = [:]
        var base = 8 + nPages*4 + 4   // + footer size field skip handled by absolute offsets
        _ = base
        var abs = 8 + nPages*4        // page data começa após header+offsets (o campo seguinte é o 1º tamanho de página)
        // offsets no header são tamanhos de página; converte em posições absolutas
        var pos = abs + 4
        for size in pageOffsets {
            let pageStart = pos
            // dentro da página: [0x0100][numCookies LE][cookieOffsets...]
            let nc = Int(u32le(pageStart+4))
            for i in 0..<nc {
                let co = pageStart + Int(u32le(pageStart+8+i*4))
                guard co+40 <= d.count else { continue }
                let urlOff = co + Int(u32le(co+16))
                let nameOff = co + Int(u32le(co+20))
                let valOff  = co + Int(u32le(co+28))
                func cstr(_ start: Int) -> String { var e=start; while e<d.count && d[e] != 0 { e+=1 }; return String(data: d[start..<e], encoding: .utf8) ?? "" }
                let dom = cstr(urlOff)
                if dom == host || dom == "."+host || dom.hasSuffix("."+host) || dom == "."+host {
                    out[cstr(nameOff)] = cstr(valOff)
                }
            }
            pos = pageStart + size
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
