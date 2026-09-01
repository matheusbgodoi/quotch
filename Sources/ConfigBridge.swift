import SwiftUI
import Combine

/// Ponte config → modelo da notch. Reconstrói os slots quando a configuração muda,
/// leva a conta recém-adicionada para a frente do seu stack e dispara a leitura
/// DEPOIS que o modelo já atualizou (senão o refresh corre antes da conta existir).
@MainActor
final class NotchConfigBridge {
    private let store: ConfigStore
    private let model: NotchModel
    private var bag = Set<AnyCancellable>()
    private var knownIDs = Set<UUID>()

    /// Chamado quando a CONTAGEM de slots muda (a altura do painel depende dela).
    var onSlotCountChange: (() -> Void)?
    /// Chamado quando borda/visibilidade mudam.
    var onLayoutChange: ((NotchEdge, NotchVisibility) -> Void)?

    init(store: ConfigStore, model: NotchModel) {
        self.store = store
        self.model = model
        store.$config
            .removeDuplicates()
            .sink { [weak self] cfg in self?.apply(cfg) }
            .store(in: &bag)
        apply(store.config)
    }

    func apply(_ cfg: AppConfig) {
        onLayoutChange?(cfg.notchEdge, cfg.notchVisibility)
        if model.showEmails != cfg.showEmails { model.showEmails = cfg.showEmails }
        if model.showPercentages != cfg.showPercentages { model.showPercentages = cfg.showPercentages }
        if model.groupByCategory != cfg.groupByCategory { model.groupByCategory = cfg.groupByCategory }

        // Preserva a leitura já pintada de cada conta; conta nova entra em `.noData`.
        let previous = Dictionary(model.slots.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        let ordered = cfg.notchOrder
        let cap = NotchCapacity.maxSlots()
        let shown = ordered.count > cap ? Array(ordered.prefix(cap)) : ordered

        var seen: [ProviderKind: Int] = [:]
        let slots = shown.map { account -> AccountSlot in
            let nth = seen[account.kind, default: 0]; seen[account.kind] = nth + 1
            let isBrowser = account.chromeProfile != nil
            return AccountSlot(
                id: account.id,
                kind: account.glyph.drawableKind ?? account.kind,
                nickname: account.nickname,
                state: previous[account.id] ?? (QuotchDemo ? NotchConfigBridge.demoState(for: account, nth: nth) : .noData),
                email: account.email,
                displayName: account.name,
                plan: account.plan,
                isActive: account.kind == .claude && account.nickname.isEmpty && !isBrowser,
                chromeProfile: account.chromeProfile)
        }

        guard slots != model.slots else { return }
        let countChanged = slots.count != model.slots.count
        model.slots = slots
        if let h = model.hoveredIndex, h >= slots.count { model.hoveredIndex = nil }
        if countChanged { onSlotCountChange?() }

        // Contas novas: agora que model.slots já existe, traz a mais recente para a
        // frente do seu stack (o usuário vê na hora) e dispara a leitura sem corrida.
        let ids = Set(slots.map { $0.id })
        let added = ids.subtracting(knownIDs)
        let firstRun = knownIDs.isEmpty
        knownIDs = ids
        if !added.isEmpty && !firstRun {
            for id in added {
                guard let slot = slots.first(where: { $0.id == id }) else { continue }
                if let st = model.stacks.first(where: { $0.kind == slot.kind }),
                   let within = st.accounts.firstIndex(where: { $0.id == id }) {
                    model.frontIndex[slot.kind] = within
                }
            }
            model.isExpanded = true
            NotificationCenter.default.post(name: .quotchRefresh, object: nil)
        }
    }

    /// Valores de demonstração enquanto os provedores reais não existem.
    static func demoState(for a: AccountConfig, nth: Int = 0) -> CellState {
        switch a.kind {
        case .claude:      return nth == 0 ? .reading(fraction: 0.27) : .reading(fraction: 0.91)
        case .cursor:      return .reading(fraction: 0.0)
        case .codex:       return .stale(fraction: 0.82)
        case .antigravity: return .noData
        case .flow:        return .reading(fraction: 0.64)
        }
    }
}

/// Cinto de segurança: quantos anéis cabem na borda sem vazar da tela.
enum NotchCapacity {
    static func maxSlots(for screen: NSScreen? = NSScreen.main) -> Int {
        guard let screen else { return 4 }
        let usable = screen.visibleFrame.height - NQ.cellTopPadding - NQ.cellBottomPadding - 2 * NQ.endMargin
        return max(1, Int(usable / NQ.verticalStep))
    }
}
