import AppKit
import SwiftUI
import ObjectiveC

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var bridge: NotchConfigBridge?
    private var coordinator: RefreshCoordinator?
    private let model = NotchModel.mock()
    private let store = ConfigStore.shared

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // fora da Dock; vira .regular com o Settings aberto

        SettingsWindowController.shared.configure(store: store)
        NQMainMenu.install()

        model.applyVisibility(store.config.notchVisibility)
        controller = NotchWindowController(model: model)
        controller?.edge = store.config.notchEdge

        NQMenuActions.shared.onRefresh = { [weak self] in self?.coordinator?.refreshAll() }
        NQMenuActions.shared.onTogglePin = { [weak self] in
            guard let self else { return }
            self.model.isPinned.toggle()
            self.model.applyVisibility(self.store.config.notchVisibility)
        }

        let b = NotchConfigBridge(store: store, model: model)
        b.onSlotCountChange = { [weak self] in self?.controller?.scheduleRelayout() }
        b.onLayoutChange = { [weak self] edge, vis in
            guard let self, let c = self.controller else { return }
            if c.edge != edge { c.edge = edge }
            c.scheduleRelayout()
            if self.model.visibility != vis { self.model.applyVisibility(vis) }
        }
        bridge = b
        if !QuotchDemo { coordinator = RefreshCoordinator(model: model, store: store) }
        controller?.coordinator = coordinator

        // App em primeiro plano (ex.: abrir Ajustes) → tenta ler de novo. É quando o
        // macOS deixa o diálogo do Keychain ("Sempre Permitir") aparecer.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            NotificationCenter.default.post(name: .quotchRefresh, object: nil)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.controller?.scheduleRelayout() }
            }
    }

    /// Reabrir pelo Finder/Spotlight traz os Ajustes (resgate quando a notch está "Hide").
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    objc_setAssociatedObject(app, "nq.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
