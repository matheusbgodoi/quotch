import SwiftUI

let QuotchDemo = FileManager.default.fileExists(atPath: "/tmp/quotch-demo")

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case claude, codex, cursor, antigravity, flow, grok
    var id: String { rawValue }
    var category: ProviderCategory { self == .flow ? .generation : .coding }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        case .flow: return "Flow"
        case .grok: return "Grokbot"
        }
    }
    /// Site aberto ao clicar. Passa pelo Escolher Navegador (esquema abrir://),
    /// com fallback para https se o handler não existir.
    var manageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/#settings/Account")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        case .antigravity: return URL(string: "https://antigravity.google")!
        case .flow: return URL(string: "https://labs.google/fx/tools/flow")!
        case .grok: return URL(string: "https://grok.com")!
        }
    }
}

enum ProviderCategory: String, Codable { case coding, generation }

enum CellState: Equatable {
    case reading(fraction: Double, weekly: Double? = nil)
    case noData
    case stale(fraction: Double)
}

/// Uma conta = um slot na notch. A ORDEM é a posição no array — não existe
/// campo `order` (fonte dupla de verdade desalinhava hoveredIndex e cellRects).
struct AccountSlot: Identifiable, Equatable {
    let id: UUID
    var kind: ProviderKind
    var nickname: String
    var state: CellState
    var email: String? = nil
    var displayName: String? = nil   // nome da pessoa
    var plan: String? = nil
    var isActive: Bool = false        // ferramenta trabalhando agora → spinner
    var chromeProfile: String? = nil  // perfil do Chrome (Claude via navegador)
    /// O que identifica a conta para o usuário: apelido, senão nome, senão e-mail.
    var title: String { nickname.isEmpty ? (displayName ?? email ?? kind.displayName) : nickname }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var slots: [AccountSlot]
    @Published var hoveredIndex: Int?
    @Published var isExpanded: Bool = false
    @Published var isPinned: Bool = false          // "Keep open" do menu de contexto
    @Published var isHoveringSettings: Bool = false
    @Published var isHoveringBody: Bool = false
    @Published var frontIndex: [ProviderKind: Int] = [:]
    @Published var refreshToken: [UUID: Int] = [:]
    @Published var readings: [UUID: UsageReading] = [:]
    @Published var showEmails: Bool = true
    @Published var showPercentages: Bool = true
    @Published var groupByCategory: Bool = true
    func setState(_ id: UUID, _ st: CellState) {
        if let i = slots.firstIndex(where: { $0.id == id }) { slots[i].state = st }
    }
    @Published var visibility: NotchVisibility = ProcessInfo.processInfo.environment["NQ_ALWAYS"] != nil ? .alwaysShow : .onHover

    init(slots: [AccountSlot]) {
        self.slots = slots
        self.isExpanded = (visibility == .alwaysShow)
    }

    func applyVisibility(_ v: NotchVisibility) {
        visibility = v
        isExpanded = (v == .alwaysShow) || isPinned
    }

    static func mock() -> NotchModel {
        NotchModel(slots: [
            .init(id: UUID(), kind: .claude,      nickname: "pessoal",  state: .reading(fraction: 0.27)),
            .init(id: UUID(), kind: .claude,      nickname: "trabalho", state: .reading(fraction: 0.91)),
            .init(id: UUID(), kind: .cursor,      nickname: "pessoal",  state: .reading(fraction: 0.00)),
            .init(id: UUID(), kind: .codex,       nickname: "work",     state: .stale(fraction: 0.82)),
            .init(id: UUID(), kind: .antigravity, nickname: "main",     state: .noData),
            .init(id: UUID(), kind: .flow,        nickname: "ultra",    state: .reading(fraction: 0.64)),
        ])
    }
}
