import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Comportamento de Dock
//
// Pedido explícito (docs/requisitos.md): por padrão o app fica FORA da Dock (.accessory);
// com o Settings aberto vira .regular e aparece na Dock; ao fechar volta a .accessory e some.
//
// Três armadilhas resolvidas aqui, todas verificáveis:
//
// 1. `SettingsLink`/cena `Settings` do SwiftUI exige o ciclo de vida `App`. Este projeto sobe
//    por `main.swift` com `NSApplication`, então a cena não existe e `SettingsLink` não compila
//    fora de uma `Scene` — nem serve para um item de NSMenu. Por isso: NSWindow própria com
//    `NSHostingView`. De brinde ganhamos título, autosave de frame e controlo do nível da janela.
//
// 2. `isReleasedWhenClosed` é `true` por padrão em NSWindow criada por código. Com ARC, fechar
//    a janela liberta o objeto e a segunda abertura vai num ponteiro morto. Tem de ser `false`.
//
// 3. Voltar para `.accessory` DENTRO de `windowWillClose` deixa a Dock com um ícone fantasma e
//    o app "ativo sem janela". A troca tem de acontecer no ciclo seguinte do run loop, e vem
//    acompanhada de `NSApp.deactivate()` para o foco voltar ao app anterior.
//
// 4. Em `.regular` sem `mainMenu` o app fica sem barra de menus — e, pior, sem menu Edit os
//    atalhos ⌘C/⌘V/⌘A não funcionam DENTRO dos TextField de renomear conta. Por isso
//    `NQMainMenu.install()`.

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// `true` = a janela flutua acima das outras enquanto está aberta (pedido do usuário).
    static var floating = true

    private var window: NSWindow?
    private var store: ConfigStore?
    private var isClosing = false

    func configure(store: ConfigStore) { self.store = store }

    var isOpen: Bool { window?.isVisible ?? false }

    func toggle() { isOpen ? close() : show() }

    func show() {
        QTLog.write("Settings.show store=\(store != nil) window=\(window != nil) policy=\(NSApp.activationPolicy().rawValue)")
        guard let store else { return }
        isClosing = false

        if window == nil {
            let host = NSHostingView(rootView: SettingsRootView(store: store))
            host.frame = NSRect(x: 0, y: 0, width: NQSettings.width, height: NQSettings.height)

            let w = NSWindow(contentRect: host.frame,
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered,
                             defer: false)
            w.title = NQSettings.title
            w.contentView = host
            w.delegate = self
            w.isReleasedWhenClosed = false          // (2)
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.level = SettingsWindowController.floating ? .floating : .normal
            w.setFrameAutosaveName("nq.settings.window")
            w.center()
            window = w
        }

        NSApp.setActivationPolicy(.regular)          // entra na Dock
        NQMainMenu.install()                         // (4)
        // A troca de policy só vale no próximo ciclo do run loop; ativar no mesmo
        // tick deixa a janela atrás. Por isso o despacho.
        let w = window
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            w?.makeKeyAndOrderFront(nil)
            w?.orderFrontRegardless()
        }
    }

    func close() { window?.performClose(nil) }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window, !isClosing else { return }
        isClosing = true
        store?.save()                                // grava agora, sem esperar o debounce
        // (3) — a troca de política precisa de um ciclo de run loop depois do fecho.
        DispatchQueue.main.async { [weak self] in
            NSApp.setActivationPolicy(.accessory)    // sai da Dock
            NSApp.deactivate()
            self?.isClosing = false
        }
    }
}

// MARK: - Barra de menus mínima

@MainActor
enum NQMainMenu {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        let appName = "Quotch"
        let main = NSMenu()

        // App
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: Selector(("orderFrontStandardAboutPanel:")), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…",
                                       action: #selector(NQMenuActions.openSettings(_:)), keyEquivalent: ",")
        settings.target = NQMenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: Selector(("hide:")), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: Selector(("hideOtherApplications:")), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: Selector(("terminate:")), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit — sem isto, ⌘C/⌘V/⌘A não funcionam nos TextField de renomear conta.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: Selector(("delete:")), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // Window
        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimise", action: Selector(("performMiniaturize:")), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: Selector(("performClose:")), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}

// MARK: - Ações partilhadas (menu de contexto da notch, barra de menus, URL scheme)

@MainActor
final class NQMenuActions: NSObject {
    static let shared = NQMenuActions()

    /// Ligado pelo AppDelegate: refresh manual e pin da notch vivem na camada da notch.
    var onRefresh: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var isPinned: () -> Bool = { false }

    @objc func openSettings(_ sender: Any?) { SettingsWindowController.shared.show() }
    @objc func refreshNow(_ sender: Any?) { onRefresh?() }
    @objc func toggleKeepOpen(_ sender: Any?) { onTogglePin?() }
    @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }

    /// Menu de contexto da notch — mesmos itens e mesma ordem de referência.
    func notchMenu() -> NSMenu {
        let menu = NSMenu()
        let keep = NSMenuItem(title: "Keep open", action: #selector(toggleKeepOpen(_:)), keyEquivalent: "")
        keep.target = self
        keep.state = isPinned() ? .on : .off
        menu.addItem(keep)

        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow(_:)), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Quotch", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// Abre o menu em coordenadas de ECRÃ, sem ativar o app (a notch é um painel não-ativante).
    func popUpNotchMenu(at screenPoint: NSPoint) {
        notchMenu().popUp(positioning: nil, at: screenPoint, in: nil)
    }
}

// MARK: - Abrir o Settings sem Dock e sem barra de menus
//
// O app arranca em `.accessory` e não tem item na barra de menus: precisa de portas de entrada.
// Quatro, por ordem de custo:
//
//   1. Clique direito na notch  → `NQMenuActions.popUpNotchMenu` (ligado em NotchPanel.swift).
//   2. Reabrir o app no Finder/Spotlight/Launchpad → `applicationShouldHandleReopen`.
//      É a porta que a própria copy de referência promete no help de "Hide":
//      "Open Quotch again from Applications to bring these settings back."
//   3. `open quotch://settings` no Terminal ou de qualquer script → `application(_:open:)`.
//   4. Atalho global ⌥⌘, — via Carbon `RegisterEventHotKey`, que NÃO pede permissão de
//      Acessibilidade (ao contrário de um monitor global de teclado ou de um CGEventTap).
//      É a única API de atalho global sem TCC, e o app promete não pedir Acessibilidade.

@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// ⌥⌘, por padrão (`kVK_ANSI_Comma` = 0x2B).
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_Comma),
                  modifiers: UInt32 = UInt32(cmdKey | optionKey),
                  action: @escaping () -> Void) {
        unregister()
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.signature == GlobalHotKey.signature {
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.fire() } }
            }
            return noErr
        }, 1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: GlobalHotKey.signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    fileprivate func fire() { action?() }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private static let signature: OSType = 0x4E51_5541   // 'NQUA'
}
