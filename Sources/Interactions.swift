import AppKit
import SwiftUI

/// Ponte Objective-C para os NSMenuItem. Equivale ao `the reference notch app.MenuActions`.
@MainActor
final class MenuActions: NSObject {
    var onTogglePin:    () -> Void   = {}
    var onRefreshNow:   () -> Void   = {}
    var onOpenSettings: () -> Void   = {}
    var onOpenSlot:     (Int) -> Void = { _ in }

    @objc func togglePinned(_ sender: Any?)   { onTogglePin() }
    @objc func refreshNow(_ sender: Any?)     { onRefreshNow() }
    @objc func openSettings(_ sender: Any?)   { onOpenSettings() }
    @objc func openSlot(_ sender: NSMenuItem) { onOpenSlot(sender.tag) }
}

extension ProviderKind {
    /// Sempre via `abrir://` (Escolher Navegador.app), como manda docs/requisitos.md.
    /// Os quatro primeiros são literais tirados do binário de referência.
    var usageURL: URL? {
        switch self {
        case .claude:      return URL(string: "abrir://claude.ai/settings/usage")
        case .codex:       return URL(string: "abrir://chatgpt.com/#settings/Account")
        case .cursor:      return URL(string: "abrir://cursor.com/dashboard")
        case .antigravity: return URL(string: "abrir://antigravity.google")
        case .flow:        return URL(string: "abrir://labs.google/fx/tools/flow")
        case .grok:        return URL(string: "abrir://grok.com")
        }
    }
}

extension NotchModel {
    /// A ordem é a posição no array — não existe mais campo `order`.
    var ordered: [AccountSlot] { slots }
}

@MainActor
extension NotchWindowController {

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 1. "Keep open" — toggle com estado, sem atalho (igual ao original).
        let keep = NSMenuItem(title: "Keep open",
                              action: #selector(MenuActions.togglePinned(_:)),
                              keyEquivalent: "")
        keep.target = actions
        keep.state = model.isPinned ? .on : .off
        menu.addItem(keep)

        menu.addItem(.separator())

        // 2. "Refresh now" ⌘R
        let refresh = NSMenuItem(title: "Refresh now",
                                 action: #selector(MenuActions.refreshNow(_:)),
                                 keyEquivalent: "r")
        refresh.target = actions
        menu.addItem(refresh)

        // 3. NOVO: o the reference notch app não tem isto. É o caminho óbvio que faltava.
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(MenuActions.openSettings(_:)),
                                  keyEquivalent: ",")
        settings.target = actions
        menu.addItem(settings)

        menu.addItem(.separator())

        // 4. Um item por conta, com tag = índice (igual ao laço de `signIn:`).
        for (i, slot) in model.ordered.enumerated() {
            let it = NSMenuItem(title: "Open \(slot.kind.displayName) · \(slot.nickname)",
                                action: #selector(MenuActions.openSlot(_:)),
                                keyEquivalent: "")
            it.target = actions
            it.tag = i
            menu.addItem(it)
        }

        menu.addItem(.separator())

        // 5. Quit ⌘Q
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    /// Clique numa célula: atualizar a leitura daquela conta (giro do arco branco).
    func refresh(stackIndex i: Int) {
        guard i < model.stacks.count else { return }
        let front = model.stacks[i].front
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.refreshSpin) { model.refreshToken[front.id, default: 0] += 1 }
        coordinator?.refresh(front)
    }

    func open(kind: ProviderKind, slot: AccountSlot) {
        guard let url = kind.usageURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Os pontinhos ficam nos 16 pt de baixo da célula (coordenadas de janela, origem embaixo).
    func clickIsOnDots(stackIndex i: Int) -> Bool {
        guard let pt = lastClickPoint, cellRectsWindow.indices.contains(i) else { return false }
        let r = cellRectsWindow[i]
        return pt.y < r.minY + 22
    }

    func open(slotAt index: Int) {
        let list = model.ordered
        guard list.indices.contains(index), let url = list[index].kind.usageURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Clique numa célula = abrir a conta que está sob o cursor.
    func handleClick() {
        QTLog.write("handleClick hoverSettings=\(model.isHoveringSettings) hovered=\(String(describing: model.hoveredIndex))")
        if model.isHoveringSettings { SettingsWindowController.shared.show(); return }
        guard let i = model.hoveredIndex, i < model.stacks.count else { return }
        let st = model.stacks[i]
        // Clique na parte de baixo da célula (onde estão os pontinhos) gira a pilha.
        if st.count > 1, clickIsOnDots(stackIndex: i) {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.flip) { model.cycle(st.kind) }
            return
        }
        refresh(stackIndex: i)
    }
}

enum QTLog {
    static func write(_ m: String) {
        guard FileManager.default.fileExists(atPath: "/tmp/qt-hitlog") else { return }
        if let h = FileHandle(forWritingAtPath: "/tmp/qt-hit.log") { h.seekToEndOfFile(); h.write((m + "\n").data(using: .utf8)!); h.closeFile() }
    }
}
