import Foundation
import AppKit

/// Ler cookies de qualquer navegador (Chrome, Safari…) de dentro de OUTRO app exige
/// Full Disk Access no macOS moderno. Sem isso, a cópia do arquivo falha com EPERM.
enum BrowserAccess {
    /// Consegue ler os dados de navegador? (testa o Cookies do Chrome e o do Safari)
    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies").path,
            home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies").path,
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies").path,
        ]
        for p in probes where FileManager.default.fileExists(atPath: p) {
            if let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: p)) {
                defer { try? fh.close() }
                if (try? fh.read(upToCount: 4)) != nil { return true }
            }
        }
        return false
    }
    static func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }
}
