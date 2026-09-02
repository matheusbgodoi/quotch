import AppKit
import Foundation
import SwiftUI

// MARK: - Glifo por conta
// O the reference notch app tem 1 glifo por provedor. Aqui o glifo é da CONTA: duas contas Claude
// podem usar marcas diferentes (ou nenhuma) para o usuário distinguir os anéis.

enum GlyphID: String, Codable, CaseIterable, Identifiable {
    case claude, openai, cursor, antigravity, flow, grok, generic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude:      return "Claude"
        case .openai:      return "OpenAI"
        case .cursor:      return "Cursor"
        case .antigravity: return "Antigravity"
        case .flow:        return "Flow"
        case .grok:        return "Grokbot"
        case .generic:     return "No mark"
        }
    }

    /// `Glyph` (Glyphs.swift) ainda é indexado por `ProviderKind`; `.generic` não tem
    /// correspondente e é desenhado como anel sem marca.
    var drawableKind: ProviderKind? {
        switch self {
        case .claude:      return .claude
        case .openai:      return .codex
        case .cursor:      return .cursor
        case .antigravity: return .antigravity
        case .flow:        return .flow
        case .grok:        return .grok
        case .generic:     return nil
        }
    }
}

// MARK: - Metadados de provedor (o `ProviderDescriptor` do spec §1.2, em forma mínima)

enum MultiAccountMode {
    /// Várias credenciais coexistem sem intervenção (Flow: 1 WKWebView por conta).
    case native
    /// A ferramenta dona guarda 1 conta; capturamos cópias (Claude, Codex, Cursor, Antigravity).
    case snapshotOfActive
}

extension ProviderKind {
    var defaultGlyph: GlyphID {
        switch self {
        case .claude:      return .claude
        case .codex:       return .openai       // o original também usa glyph "openai" para codex
        case .cursor:      return .cursor
        case .antigravity: return .antigravity
        case .flow:        return .flow
        case .grok:        return .grok
        }
    }

    /// Nome da ferramenta DONA da credencial — é o que aparece em "via …".
    var toolName: String {
        switch self {
        case .claude:      return "Claude Code"
        case .codex:       return "Codex"
        case .cursor:      return "Cursor"
        case .antigravity: return "Antigravity"
        case .flow:        return "Google Flow"
        case .grok:        return "Grokbot"
        }
    }

    /// Host mostrado no botão "Open …".
    var site: String {
        switch self {
        case .claude:      return "claude.ai"
        case .codex:       return "chatgpt.com"
        case .cursor:      return "cursor.com"
        case .antigravity: return "antigravity.google"
        case .flow:        return "labs.google"
        case .grok:        return "grok.com"
        }
    }

    /// Caminho completo, sem esquema — o esquema é escolhido em `NQLink`.
    var managePath: String {
        switch self {
        case .claude:      return "claude.ai/settings/usage"
        case .codex:       return "chatgpt.com/#settings/Account"
        case .cursor:      return "cursor.com/dashboard"
        case .antigravity: return "antigravity.google"
        case .flow:        return "labs.google/fx/tools/flow"
        case .grok:        return "grok.com"
        }
    }

    var multiAccountMode: MultiAccountMode { self == .flow ? .native : .snapshotOfActive }

    /// Help do link "Switch…" — texto literal de referência, com o nome da ferramenta interpolado.
    var switchHelp: String {
        switch self {
        case .claude:
            return "Run Claude Code once — it signs in and refreshes the token this reads. Use /login there to change account."
        case .codex, .cursor, .antigravity, .grok:
            return "Switch accounts in \(toolName); the notch follows."
        case .flow:
            return "Sign out in the \(toolName) window to use another account."
        }
    }

    /// Empty state por provedor (literais do original).
    var signInHint: String {
        switch self {
        case .claude:      return "Sign in to Claude Code to read your usage"
        case .codex:       return "Sign in to Codex to read your usage"
        case .cursor:      return "Sign in to Cursor in the editor"
        case .antigravity: return "Sign in to Antigravity to read your usage"
        case .flow:        return "Sign in with Google Flow"
        case .grok:        return "Sign in to Grok in your browser"
        }
    }
}

extension ProviderCategory {
    /// Cabeçalho do grupo quando `groupByCategory` está ligado.
    var title: String { self == .coding ? "Coding" : "Generation" }
    var order: Int { self == .coding ? 0 : 1 }
}

// MARK: - Preferências da notch

enum NotchEdge: String, Codable, CaseIterable, Identifiable {
    case right, top, bottom, left
    var id: String { rawValue }
    var title: String {
        switch self {
        case .right:  return "Right"
        case .top:    return "Top"
        case .bottom: return "Bottom"
        case .left:   return "Left"
        }
    }
    var help: String {
        switch self {
        case .right:  return "Down the right-hand edge, clear of a Dock on that side."
        case .top:    return "A wide bar across the top, readings side by side. On a Mac with a notch of its own it runs up to meet it, so the two read as one shape."
        case .bottom: return "A wide bar resting on top of the Dock, readings side by side."
        case .left:   return "Down the left-hand edge, clear of a Dock on that side."
        }
    }
}

enum NotchVisibility: String, Codable, CaseIterable, Identifiable {
    case alwaysShow, onHover, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .alwaysShow: return "Always show"
        case .onHover:    return "Show on hover"
        case .hidden:     return "Hide"
        }
    }
    var help: String {
        switch self {
        case .alwaysShow: return "The notch stays open with every reading visible."
        case .onHover:    return "A small pill at the screen edge that opens when you reach it."
        case .hidden:     return "Nothing on screen. Open Quotch again from Applications to bring these settings back."
        }
    }
}

// MARK: - Conta

struct AccountConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: ProviderKind
    /// Nome dado pelo usuário. Vazio = a UI mostra `email ?? kind.displayName`.
    var nickname: String
    var email: String?
    var name: String?
    var plan: String?
    var chromeProfile: String?   // dir do perfil do Chrome; nil = ferramenta de desktop
    var glyph: GlyphID
    /// Aparece na notch? (equivalente multi-conta do `hiddenProviders`)
    var isVisible: Bool
    /// Lida ativamente? false = "signed out": não lê e esquece as leituras.
    var isEnabled: Bool
    var createdAt: Date

    init(id: UUID = UUID(),
         kind: ProviderKind,
         nickname: String = "",
         email: String? = nil,
         name: String? = nil,
         plan: String? = nil,
         chromeProfile: String? = nil,
         glyph: GlyphID? = nil,
         isVisible: Bool = true,
         isEnabled: Bool = true,
         createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.nickname = nickname
        self.email = email
        self.name = name
        self.plan = plan
        self.chromeProfile = chromeProfile
        self.glyph = glyph ?? kind.defaultGlyph
        self.isVisible = isVisible
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// Nome mostrado em qualquer lugar que precise identificar a conta em uma linha.
    var title: String {
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        if let email, !email.isEmpty { return email }
        return kind.displayName
    }

    /// Subtítulo da linha: "<e-mail> · via <ferramenta> · <Plano>"
    var subtitle: String { subtitle(showEmail: true) }
    func subtitle(showEmail: Bool) -> String {
        var parts: [String] = []
        if showEmail, let email, !email.isEmpty { parts.append(email) }
        else if let name, !name.isEmpty { parts.append(name) }
        parts.append("via \(kind.toolName)")
        if let plan, !plan.isEmpty { parts.append(plan.capitalized) }
        return parts.joined(separator: " · ")   // U+00B7, como no original
    }

    // Decodificação tolerante: chave ausente nunca derruba o load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(ProviderKind.self, forKey: .kind)) ?? .claude
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.kind = kind
        self.nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        self.email = try? c.decodeIfPresent(String.self, forKey: .email)
        self.name = try? c.decodeIfPresent(String.self, forKey: .name)
        self.chromeProfile = try? c.decodeIfPresent(String.self, forKey: .chromeProfile)
        self.plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        self.glyph = (try? c.decode(GlyphID.self, forKey: .glyph)) ?? kind.defaultGlyph
        self.isVisible = (try? c.decode(Bool.self, forKey: .isVisible)) ?? true
        self.isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
        self.createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

// MARK: - Configuração persistida

struct AppConfig: Codable, Equatable {
    /// A ORDEM DESTE ARRAY É A ORDEM NA NOTCH.
    var accounts: [AccountConfig]
    var readClaudeKeychain: Bool = false
    var showEmails: Bool = true
    var notchEdge: NotchEdge
    var notchVisibility: NotchVisibility
    var groupByCategory: Bool
    var showPercentages: Bool
    var refreshInterval: TimeInterval
    var idleRefreshInterval: TimeInterval
    var schemaVersion: Int

    static let defaults = AppConfig(accounts: [],
                                    notchEdge: .right,
                                    notchVisibility: .onHover,
                                    groupByCategory: true,
                                    showPercentages: true,
                                    refreshInterval: 300,
                                    idleRefreshInterval: 900,
                                    schemaVersion: ConfigMigration.currentVersion)

    init(accounts: [AccountConfig],
         notchEdge: NotchEdge,
         notchVisibility: NotchVisibility,
         groupByCategory: Bool,
         showPercentages: Bool,
         refreshInterval: TimeInterval,
         idleRefreshInterval: TimeInterval,
         schemaVersion: Int) {
        self.accounts = accounts
        self.notchEdge = notchEdge
        self.notchVisibility = notchVisibility
        self.groupByCategory = groupByCategory
        self.showPercentages = showPercentages
        self.refreshInterval = refreshInterval
        self.idleRefreshInterval = idleRefreshInterval
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.defaults
        self.accounts = (try? c.decode([AccountConfig].self, forKey: .accounts)) ?? d.accounts
        self.notchEdge = (try? c.decode(NotchEdge.self, forKey: .notchEdge)) ?? d.notchEdge
        self.notchVisibility = (try? c.decode(NotchVisibility.self, forKey: .notchVisibility)) ?? d.notchVisibility
        self.groupByCategory = (try? c.decode(Bool.self, forKey: .groupByCategory)) ?? d.groupByCategory
        self.showPercentages = (try? c.decode(Bool.self, forKey: .showPercentages)) ?? d.showPercentages
        self.refreshInterval = (try? c.decode(TimeInterval.self, forKey: .refreshInterval)) ?? d.refreshInterval
        self.idleRefreshInterval = (try? c.decode(TimeInterval.self, forKey: .idleRefreshInterval)) ?? d.idleRefreshInterval
        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? ConfigMigration.currentVersion
    }

    /// Ordem dos provedores = ordem de primeira aparição no array de contas.
    var orderedKinds: [ProviderKind] {
        var seen: [ProviderKind] = []
        for a in accounts where !seen.contains(a.kind) { seen.append(a.kind) }
        return seen
    }

    func accounts(of kind: ProviderKind) -> [AccountConfig] { accounts.filter { $0.kind == kind } }

    /// Reagrupa mantendo a ordem de primeira aparição: contas do mesmo provedor
    /// ficam contíguas, o que é o que torna o drag por grupo previsível.
    func regrouped() -> [AccountConfig] {
        orderedKinds.flatMap { k in accounts.filter { $0.kind == k } }
    }

    /// O que a notch desenha, já na ordem final.
    var notchOrder: [AccountConfig] {
        let live = regrouped().filter { $0.isVisible && $0.isEnabled }
        guard groupByCategory else { return live }
        return live.enumerated()
            .sorted { a, b in
                let ca = a.element.kind.category.order, cb = b.element.kind.category.order
                return ca == cb ? a.offset < b.offset : ca < cb
            }
            .map(\.element)
    }
}

// MARK: - Migração de schema

enum ConfigMigration {
    static let currentVersion = 2

    /// Migra o JSON cru antes de decodificar. Cada passo é v→v+1 e só mexe no dicionário,
    /// para nunca depender do formato ATUAL do struct (que continua mudando).
    static func migrated(_ data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        var v = root["schemaVersion"] as? Int ?? 1
        while v < currentVersion {
            switch v {
            case 1:  root = v1_to_v2(root)
            default: break
            }
            v += 1
            root["schemaVersion"] = v
        }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// v1 (spec §2.3) → v2:
    /// • `showPercentLabels` virou `showPercentages`
    /// • conta ganhou `glyph`, `isVisible`, `isEnabled`
    /// • o campo `order` por conta sumiu: a ordem passou a ser a do array
    private static func v1_to_v2(_ input: [String: Any]) -> [String: Any] {
        var root = input
        if let legacy = root.removeValue(forKey: "showPercentLabels") {
            root["showPercentages"] = legacy
        }
        if var accounts = root["accounts"] as? [[String: Any]] {
            accounts.sort { (($0["order"] as? Int) ?? 0) < (($1["order"] as? Int) ?? 0) }
            for i in accounts.indices {
                accounts[i].removeValue(forKey: "order")
                if accounts[i]["glyph"] == nil {
                    let kind = accounts[i]["kind"] as? String ?? "claude"
                    accounts[i]["glyph"] = (ProviderKind(rawValue: kind) ?? .claude).defaultGlyph.rawValue
                }
                if accounts[i]["isVisible"] == nil { accounts[i]["isVisible"] = true }
                if accounts[i]["isEnabled"] == nil { accounts[i]["isEnabled"] = true }
            }
            root["accounts"] = accounts
        }
        return root
    }
}

// MARK: - Store

/// Fonte única de verdade. Um blob JSON em `UserDefaults`, chave "config" — mais fácil
/// de migrar do que doze chaves soltas (spec §2.3).
@MainActor
final class ConfigStore: ObservableObject {
    static let key = "config"
    static let shared = ConfigStore()

    @Published var config: AppConfig { didSet { if config != oldValue { scheduleSave() } } }

    private let defaults: UserDefaults
    private var saveWork: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.config = ConfigStore.load(from: defaults)
        if defaults.data(forKey: ConfigStore.key) == nil {
            save()
        }
    }

    private static func load(from defaults: UserDefaults) -> AppConfig {
        guard let raw = defaults.data(forKey: key) else { return .defaults }
        let migrated = ConfigMigration.migrated(raw)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard var cfg = try? dec.decode(AppConfig.self, from: migrated) else { return .defaults }
        cfg.schemaVersion = ConfigMigration.currentVersion
        cfg.accounts = cfg.regrouped()
        return cfg
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func save() {
        saveWork?.cancel(); saveWork = nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(config) else { return }
        defaults.set(data, forKey: ConfigStore.key)
    }

    // MARK: Bindings

    func binding<T>(_ path: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: path] },
                set: { self.config[keyPath: path] = $0 })
    }

    func binding(account id: UUID) -> Binding<AccountConfig> {
        Binding(
            get: { self.config.accounts.first { $0.id == id } ?? AccountConfig(kind: .claude) },
            set: { new in
                guard let i = self.config.accounts.firstIndex(where: { $0.id == id }) else { return }
                self.config.accounts[i] = new
            })
    }

    // MARK: Mutações

    @discardableResult
    func addAccount(kind: ProviderKind, nickname: String = "", chromeProfile: String? = nil) -> UUID {
        var new = AccountConfig(kind: kind, nickname: nickname, chromeProfile: chromeProfile)
        if let src = BrowserSource.parse(chromeProfile), kind == .claude, let id = Providers.claudeBrowserIdentity(source: src) {
            new.email = id.email; new.name = id.name; new.plan = id.plan
        } else if chromeProfile == nil, let id = IdentityProbe.probe(kind) {
            new.email = id.email; new.name = id.name; new.plan = id.plan
        }
        // Duas contas do mesmo provedor sem apelido são indistinguíveis: numera a partir da 2ª.
        let siblings = config.accounts(of: kind)
        if nickname.isEmpty && !siblings.isEmpty { new.nickname = "\(kind.displayName) \(siblings.count + 1)" }
        config.accounts.append(new)
        config.accounts = config.regrouped()
        return new.id
    }

    func setIdentity(_ id: UUID, _ ident: AccountIdentity) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        if let e = ident.email { config.accounts[i].email = e }
        if let n = ident.name { config.accounts[i].name = n }
        if let p = ident.plan { config.accounts[i].plan = p }
    }

    func removeAccount(_ id: UUID) {
        Vault.remove(id)
        config.accounts.removeAll { $0.id == id }
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        config.accounts[i].nickname = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Reordena contas DENTRO de um provedor (índices relativos ao grupo) — assinatura
    /// compatível com `ForEach.onMove`.
    func moveAccounts(in kind: ProviderKind, from source: IndexSet, to destination: Int) {
        var group = config.accounts(of: kind)
        group.move(fromOffsets: source, toOffset: destination)
        var rest = config.accounts.filter { $0.kind != kind }
        // reinsere o grupo na posição do primeiro item antigo do grupo
        let anchor = config.accounts.firstIndex { $0.kind == kind } ?? config.accounts.count
        let before = config.accounts.prefix(anchor).filter { $0.kind != kind }.count
        rest.insert(contentsOf: group, at: min(before, rest.count))
        config.accounts = rest
    }

    /// Reordena os PROVEDORES (os DisclosureGroup) — também compatível com `.onMove`.
    func moveProviders(from source: IndexSet, to destination: Int) {
        var kinds = config.orderedKinds
        kinds.move(fromOffsets: source, toOffset: destination)
        config.accounts = kinds.flatMap { k in config.accounts.filter { $0.kind == k } }
    }

    /// Drag & drop: solta `dragged` sobre `target`. Cobre os dois casos — mesmo provedor
    /// (reordena a conta) e provedores diferentes (reordena o grupo inteiro).
    func drop(_ dragged: UUID, onto target: UUID) {
        guard dragged != target,
              let from = config.accounts.firstIndex(where: { $0.id == dragged }),
              let to = config.accounts.firstIndex(where: { $0.id == target }) else { return }
        if config.accounts[from].kind == config.accounts[to].kind {
            var list = config.accounts
            let item = list.remove(at: from)
            list.insert(item, at: from < to ? to : to)
            config.accounts = list
        } else {
            let a = config.accounts[from].kind, b = config.accounts[to].kind
            var kinds = config.orderedKinds
            guard let i = kinds.firstIndex(of: a), let j = kinds.firstIndex(of: b) else { return }
            kinds.remove(at: i)
            kinds.insert(a, at: j)
            config.accounts = kinds.flatMap { k in config.accounts.filter { $0.kind == k } }
        }
    }

    /// Fallback de teclado/menu para quem não quer arrastar (e para acessibilidade).
    /// Troca a conta com a vizinha e reagrupa, para os provedores continuarem contíguos.
    func nudge(_ id: UUID, by delta: Int) {
        guard let i = config.accounts.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard config.accounts.indices.contains(j) else { return }
        var list = config.accounts
        list.swapAt(i, j)
        config.accounts = list
        config.accounts = config.regrouped()
    }

    /// Mock da fatia 1 promovido a config real, para o Settings ter o que mostrar
    /// antes dos providers existirem.
    static func seedIfEmpty(_ store: ConfigStore) {
        guard store.config.accounts.isEmpty else { return }
        store.config.accounts = [
            AccountConfig(kind: .claude, nickname: "pessoal", email: "eu@exemplo.com", plan: "max"),
            AccountConfig(kind: .claude, nickname: "trabalho", email: "trabalho@exemplo.com", plan: "pro"),
            AccountConfig(kind: .cursor, nickname: "pessoal", plan: "pro"),
            AccountConfig(kind: .codex, nickname: "work", plan: "plus"),
            AccountConfig(kind: .antigravity, nickname: "main"),
            AccountConfig(kind: .flow, nickname: "ultra", plan: "ultra"),
        ]
        store.save()
    }
}

// MARK: - Abertura de links

/// O usuário não quer que o app mande links para o navegador padrão: tudo passa pelo
/// `Escolher Navegador.app`, que atende o esquema `abrir://` (ver ~/Developer/escolher-navegador).
enum NQLink {
    /// Depois de um Switch…, re-detecta a identidade e atualiza as leituras.
    static func scheduleReconcile() {
        for d in [5.0, 20.0, 60.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                NotificationCenter.default.post(name: .quotchReconcile, object: nil)
            }
        }
    }
    static func open(_ pathWithoutScheme: String) {
        let viaChooser = URL(string: "abrir://" + pathWithoutScheme)
        let direct = URL(string: "https://" + pathWithoutScheme)
        if let u = viaChooser, NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
            NSWorkspace.shared.open(u)          // Escolher Navegador.app pergunta o alvo
        } else if let u = direct {
            NSWorkspace.shared.open(u)          // sem o chooser instalado, navegador padrão
        }
    }
}
