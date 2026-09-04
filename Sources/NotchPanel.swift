import AppKit
import SwiftUI

/// Valores exatos de referência (docs/design-tokens.md, secao "Camada de janela").
final class NotchPanel: NSPanel {
    /// Retângulos clicáveis em coordenadas da JANELA (origem no canto inferior-esquerdo).
    var interactiveRects: [CGRect] = []
    /// Fábrica do menu — reconstruída a cada clique direito para o estado de
    /// "Manter aberto" vir fresco.
    var contextMenuProvider: (() -> NSMenu?)?
    /// Clique esquerdo. Sem índice de propósito: quem sabe o índice é o modelo
    /// (`hoveredIndex`), igual ao app de referência.
    var onClick: (() -> Void)?
    var lastClickPoint: NSPoint?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel],   // 0x80
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: 25)           // .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        ignoresMouseEvents = true                     // alternado pelo hit-test
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func hits(_ event: NSEvent) -> Bool {
        let p = event.locationInWindow
        return interactiveRects.contains { $0.contains(p) }
    }

    private var pressedInside = false
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown where hits(event):
            if let menu = contextMenuProvider?(), let cv = contentView {
                NSMenu.popUpContextMenu(menu, with: event, for: cv)
            }
            return
        case .leftMouseDown:
            pressedInside = hits(event)
            if pressedInside { return }          // não deixa o SwiftUI engolir
        case .leftMouseUp:
            if pressedInside {
                pressedInside = false
                lastClickPoint = event.locationInWindow
                if hits(event) { onClick?() }
                return
            }
        default: break
        }
        super.sendEvent(event)
    }

    var onScroll: ((NSPoint, CGFloat, CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        // Passa os dois eixos: vertical (wheel comum / 2 dedos) e horizontal
        // (thumbwheel lateral do MX Master, ou swipe lateral no trackpad).
        if hits(event) { onScroll?(event.locationInWindow, event.scrollingDeltaX, event.scrollingDeltaY); return }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if hits(event), let onClick {
            onClick()
            return
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    let model: NotchModel
    private var hosting: NSHostingView<AnyView>!
    private var monitors: [Any] = []
    private var cursorTimer: Timer?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var layout: NotchLayout
    var screenChoice: ScreenChoice = .primary
    var edge: NotchEdge = .right
    var coordinator: RefreshCoordinator?
    private var relayoutWork: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    init(model: NotchModel) {
        self.model = model
        let screen = ScreenChoice.primary.resolve() ?? NSScreen.screens[0]
        layout = NotchLayoutEngine.layout(slots: model.stacks.count, edge: .right, on: screen)
        panel = NotchPanel(contentRect: layout.windowFrame)

        // Container + hosting como subview: hierarquia do binario (autoresizingMask 0x12).
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.frame = CGRect(origin: .zero, size: layout.windowFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        panel.onClick = { [weak self] in self?.handleClick() }
        panel.onScroll = { [weak self] pt, dx, dy in self?.handleScroll(at: pt, deltaX: dx, deltaY: dy) }
        rebuildRoot()
        panel.setFrame(layout.windowFrame, display: true)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NQTiming.windowFade
            panel.animator().alphaValue = 1
        }
        startHoverTracking()
        observeGeometry()
        startDebugChannel()
    }

    private func rebuildRoot() {
        let root = NotchRootView(model: model, layout: layout, onRects: { [weak self] rects in
            self?.updateRects(rects)
        }, onGearRect: { [weak self] r in
            self?.updateGearRect(r)
        }, showEmails: ConfigStore.shared.config.showEmails)
        hosting.rootView = AnyView(root)
    }

    // MARK: - Geometria

    private func observeGeometry() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRelayout() }
            }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRelayout() }
            }
    }

    /// Debounce: trocar de monitor dispara varias notificacoes seguidas.
    func scheduleRelayout() {
        relayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.relayout() }
        relayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private var lastFlip = Date.distantPast
    /// Scroll sobre uma pilha gira as contas (limite de 1 giro a cada 220 ms).
    /// Usa o eixo dominante: horizontal (thumbwheel lateral do MX Master / swipe lateral
    /// de 2 dedos) ou vertical (wheel comum). Direita/baixo = próxima conta.
    private var scrollAccum: CGFloat = 0
    private var lastScrollAt = Date.distantPast
    private func handleScroll(at pt: NSPoint, deltaX: CGFloat, deltaY: CGFloat) {
        let horizontal = abs(deltaX) >= abs(deltaY)
        let d = horizontal ? deltaX : deltaY
        guard let i = cellRectsWindow.firstIndex(where: { $0.contains(pt) }),
              i < model.stacks.count, model.stacks[i].count > 1 else { scrollAccum = 0; return }
        // Acumula o gesto: um giro só a cada ~35 pts percorridos, e no máximo 1 a cada 0,3 s.
        // Zera se o usuário parou (>0,25 s) — assim nudges soltos não empilham.
        let now = Date()
        if now.timeIntervalSince(lastScrollAt) > 0.20 || (scrollAccum != 0 && (scrollAccum < 0) != (d < 0)) { scrollAccum = 0 }
        lastScrollAt = now
        scrollAccum += d
        // Exige um gesto bem deliberado: ~140 pts de deslocamento e no máximo 1 troca a cada 0,5 s.
        guard abs(scrollAccum) >= 140, now.timeIntervalSince(lastFlip) > 0.5 else { return }
        let step = horizontal ? (scrollAccum > 0 ? 1 : -1) : (scrollAccum < 0 ? 1 : -1)
        scrollAccum = 0; lastFlip = now
        withAnimation(reduceMotion ? nil : NQMotion.flip) { model.cycle(model.stacks[i].kind, by: step) }
    }

    func relayout() {
        guard let screen = screenChoice.resolve() else { return }
        let next = NotchLayoutEngine.layout(slots: model.stacks.count, edge: edge, on: screen)
        guard next != layout else { return }          // anti-flicker: so mexe se mudou
        let frameChanged = next.windowFrame != layout.windowFrame
        layout = next
        rebuildRoot()
        if frameChanged { panel.setFrame(next.windowFrame, display: true) }
    }

    // MARK: - Hover

    private func updateRects(_ rects: [CGRect]) {
        let f = panel.frame
        cellRectsWindow = rects.map { r in
            CGRect(x: r.minX, y: f.height - r.maxY, width: r.width, height: r.height)
        }
        panel.interactiveRects = cellRectsWindow + [gearRectWindow, pillRectWindow]
        cellRectsScreen = rects.map { r in
            CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
        }
    }

    private func updateGearRect(_ r: CGRect) {
        let f = panel.frame
        gearRectScreen = CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
        gearRectWindow = CGRect(x: r.minX, y: f.height - r.maxY, width: r.width, height: r.height)
        panel.interactiveRects = cellRectsWindow + [gearRectWindow, pillRectWindow]
    }

    private func startHoverTracking() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.hitTest() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            Task { @MainActor in self?.hitTest() }
            return e
        }) { monitors.append(l) }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: NQTiming.cursorPoll, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hitTest() }
        }
        cursorTimer?.tolerance = 0.1
    }

    private var cellRectsScreen: [CGRect] = []
    private var gearRectScreen: CGRect = .zero
    private var gearRectWindow: CGRect = .zero
    /// A pílula recolhida também aceita botão direito (coordenadas de janela).
    private var pillRectWindow: CGRect {
        let f = panel.frame
        let w: CGFloat = 24, h = NQ.pillLength + 40
        switch edge {
        case .right:  return CGRect(x: f.width - w, y: f.height / 2 - h / 2, width: w, height: h)
        case .left:   return CGRect(x: 0, y: f.height / 2 - h / 2, width: w, height: h)
        case .top:    return CGRect(x: f.width / 2 - h / 2, y: f.height - w, width: h, height: w)
        case .bottom: return CGRect(x: f.width / 2 - h / 2, y: 0, width: h, height: w)
        }
    }
    var cellRectsWindow: [CGRect] = []
    var lastClickPoint: NSPoint? { panel.lastClickPoint }
    private var isPointing = false
    private var expandWork: DispatchWorkItem?
    private var foldWork: DispatchWorkItem?

    lazy var actions: MenuActions = {
        let a = MenuActions()
        a.onTogglePin    = { [weak self] in self?.togglePin() }
        a.onRefreshNow   = { [weak self] in self?.refreshNow() }
        a.onOpenSettings = { SettingsWindowController.shared.show() }
        a.onOpenSlot     = { [weak self] i in self?.open(slotAt: i) }
        return a
    }()


    private func setPointing(_ on: Bool) {
        guard on != isPointing else { return }   // sem isto a pilha de cursor do AppKit vaza
        isPointing = on
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }

    /// Faixa fina na borda direita que reabre o painel quando `notchVisibility == .onHover`.
    private var edgeTriggerScreen: CGRect {
        let f = panel.frame
        let w: CGFloat = 24, h = NQ.pillLength + 40
        switch edge {
        case .right:  return CGRect(x: f.maxX - w, y: f.midY - h / 2, width: w, height: h)
        case .left:   return CGRect(x: f.minX, y: f.midY - h / 2, width: w, height: h)
        case .top:    return CGRect(x: f.midX - h / 2, y: f.maxY - w, width: h, height: w)
        case .bottom: return CGRect(x: f.midX - h / 2, y: f.minY, width: h, height: w)
        }
    }

    // MARK: - Canal de teste (dev): /tmp/qt-cmd com "expand|collapse|hover N|unhover|flip N|settings"
    private var debugHoldUntil = Date.distantPast
    private var debugTimer: Timer?
    private func startDebugChannel() {
        guard FileManager.default.fileExists(atPath: "/tmp/qt-hitlog") else { return }
        debugTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollDebug() }
        }
    }
    private func pollDebug() {
        let path = "/tmp/qt-cmd"
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        debugHoldUntil = Date().addingTimeInterval(4)
        for raw in s.split(separator: "\n") {
            let parts = raw.split(separator: " ").map(String.init)
            guard let cmd = parts.first else { continue }
            let arg = parts.count > 1 ? Int(parts[1]) : nil
            switch cmd {
            case "expand":   withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.expand) { model.isExpanded = true }
            case "collapse": withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.expand) { model.isExpanded = false; model.hoveredIndex = nil }
            case "hover":    withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.hoverEnter) { model.hoveredIndex = arg }
            case "unhover":  withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.hoverEnter) { model.hoveredIndex = nil }
            case "flip":     if let i = arg, i < model.stacks.count { withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.flip) { model.cycle(model.stacks[i].kind) } }
            case "settings": SettingsWindowController.shared.show()
            case "settings-close": SettingsWindowController.shared.close()
            case "release":  debugHoldUntil = .distantPast
            case "capture":
                if parts.count > 1, let k = ProviderKind(rawValue: parts[1]) {
                    let id = ConfigStore.shared.addAccount(kind: k, nickname: parts.count > 2 ? parts[2] : "")
                    let ok = Vault.capture(kind: k, for: id, allowKeychain: ConfigStore.shared.config.readClaudeKeychain)
                    QTLog.write("capture \(k): \(ok)"); NotificationCenter.default.post(name: .quotchRefresh, object: nil)
                }
            case "uncapture":
                if parts.count > 1, let k = ProviderKind(rawValue: parts[1]),
                   let last = ConfigStore.shared.config.accounts.last(where: { $0.kind == k && Vault.has($0.id) }) {
                    ConfigStore.shared.removeAccount(last.id); QTLog.write("uncapture \(k) ok")
                }
            case "edge":     if parts.count > 1, let e = NotchEdge(rawValue: parts[1]) { ConfigStore.shared.config.notchEdge = e }
            case "hovergear": withAnimation(NQMotion.hoverEnter) { model.isHoveringSettings = (arg ?? 0) == 1 }
            case "addchrome":
                if parts.count > 2 {
                    ConfigStore.shared.addAccount(kind: .claude, chromeProfile: parts[1])
                    NotificationCenter.default.post(name: .quotchRefresh, object: nil)
                }
            case "pct":   ConfigStore.shared.config.showPercentages = (arg ?? 1) == 1
            case "group": ConfigStore.shared.config.groupByCategory = (arg ?? 1) == 1
            case "flowsignin":
                _ = ConfigStore.shared.addAccount(kind: .flow, chromeProfile: "safari")
                NotificationCenter.default.post(name: .quotchRefresh, object: nil)
            case "flowreconnect":
                NSWorkspace.shared.open(ProviderKind.flow.manageURL)
            case "addsrc":
                if parts.count > 2 {
                    let src = parts[2...].joined(separator: " ")
                    _ = ConfigStore.shared.addAccount(kind: ProviderKind(rawValue: parts[1]) ?? .claude, chromeProfile: src)
                    QTLog.write("addsrc \(parts[1]) src=\(src)"); NotificationCenter.default.post(name: .quotchRefresh, object: nil)
                }
            case "claudesignin":
                let cid = ConfigStore.shared.addAccount(kind: .claude, chromeProfile: "web")
                WebSession.shared.signIn(accountID: cid, kind: .claude) { ok in QTLog.write("claude signin ok=\(ok)"); NotificationCenter.default.post(name: .quotchRefresh, object: nil) }
            case "fdacheck":
                let home = FileManager.default.homeDirectoryForCurrentUser
                let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome/Profile 1/Cookies").path
                let localState = home.appendingPathComponent("Library/Application Support/Google/Chrome/Local State").path
                let safari = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies").path
                // 1) leitura direta (FDA no source)
                func tryRead(_ p: String) -> String {
                    guard FileManager.default.fileExists(atPath: p) else { return "no-file" }
                    do { let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: p)); defer { try? fh.close() }; _ = try fh.read(upToCount: 4); return "READ-OK" }
                    catch { return "READ-ERR \((error as NSError).code)" }
                }
                QTLog.write("fda chrome-cookies: \(tryRead(chrome))")
                QTLog.write("fda local-state: \(tryRead(localState))")
                QTLog.write("fda safari: \(tryRead(safari))")
                // 2) escrita no temp (dest)
                let t = FileManager.default.temporaryDirectory
                QTLog.write("fda tempdir: \(t.path)")
                let tf = t.appendingPathComponent("qt-w-\(UUID().uuidString).txt")
                do { try "x".write(to: tf, atomically: true, encoding: .utf8); try? FileManager.default.removeItem(at: tf); QTLog.write("fda tempwrite: WRITE-OK") }
                catch { QTLog.write("fda tempwrite: WRITE-ERR \((error as NSError).code) \((error as NSError).localizedDescription)") }
                QTLog.write("fda hasFDA()=\(BrowserAccess.hasFullDiskAccess())")
            case "browsertest":
                let insts = ChromiumCookies.installed()
                QTLog.write("installed: \(insts.map{$0.name+"("+$0.dir+")"})")
                for b in insts {
                    for p in ChromiumCookies.profiles(b) {
                        let cl = ChromiumCookies.hasCookie(host:"claude.ai", name:"sessionKey", browser:b, profile:p.dir)
                        QTLog.write("  \(b.name)/\(p.name)[\(p.dir)] claude=\(cl)")
                    }
                }
                QTLog.write("home=\(FileManager.default.homeDirectoryForCurrentUser.path)")
            case "reconcile": NotificationCenter.default.post(name: .quotchReconcile, object: nil)
            case "emails":   ConfigStore.shared.config.showEmails = (arg ?? 1) == 1
            case "hoverbody": withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.hoverEnter) { model.isHoveringBody = (arg ?? 0) == 1 }
            case "dump":
                let lines = model.stacks.enumerated().map { i, st in
                    "stack \(i) \(st.kind) front=\(st.frontIndex)/\(st.count) " + st.accounts.map { a in
                        "[\(a.nickname.isEmpty ? "-" : a.nickname) name=\(a.displayName ?? "nil") email=\(a.email.map { String($0.prefix(3)) + "…" } ?? "nil") state=\(a.state)]" }.joined(separator: " ")
                }
                QTLog.write(lines.joined(separator: "\n"))
            default: break
            }
        }
    }

    private func hitTest() {
        if Date() < debugHoldUntil { return }     // canal de teste segurando o estado
        let p = NSEvent.mouseLocation

        let overCell = cellRectsScreen.firstIndex { $0.contains(p) }
        let overGear = gearRectScreen.insetBy(dx: -8, dy: -10).contains(p)
        let union    = cellRectsScreen.reduce(gearRectScreen) { $0.union($1) }
        let overBody = model.isExpanded && union.insetBy(dx: -6, dy: -6).contains(p)
        let overEdge = edgeTriggerScreen.contains(p)

        // 1. Portão de eventos: só deixa passar quando há algo clicável embaixo.
        panel.ignoresMouseEvents = !(overBody || overEdge)
        if FileManager.default.fileExists(atPath: "/tmp/qt-hitlog") {
            let line = "mouse=\(p) cells=\(cellRectsScreen.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" }) gear=\(gearRectScreen) edge=\(edgeTriggerScreen) overCell=\(String(describing: overCell)) overBody=\(overBody) overEdge=\(overEdge) expanded=\(model.isExpanded) ignores=\(panel.ignoresMouseEvents)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/qt-hit.log") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        }

        // 2. Cursor.
        setPointing(overCell != nil || overGear)

        // 3. Hover — IMEDIATO, sem graça (a graça é só para abrir/fechar o painel).
        if model.hoveredIndex != overCell {
            withAnimation(reduceMotion ? nil : NQMotion.hoverEnter) { model.hoveredIndex = overCell }
        }
        if model.isHoveringBody != (overBody || overGear) {
            withAnimation(reduceMotion ? nil : NQMotion.hoverEnter) { model.isHoveringBody = overBody || overGear }
        }
        if model.isHoveringSettings != overGear {
            withAnimation(reduceMotion ? nil : NQMotion.hoverEnter) { model.isHoveringSettings = overGear }
        }

        // 4. Expandir / recolher com as graças exatas do binário (0,25 s / 0,45 s).
        // A visibilidade manda; só o modo onHover consulta o mouse.
        let wantsOpen: Bool
        switch model.visibility {
        case .alwaysShow: wantsOpen = true
        case .hidden:     wantsOpen = false
        case .onHover:    wantsOpen = model.isPinned || overBody || overEdge
        }
        if wantsOpen {
            foldWork?.cancel(); foldWork = nil
            guard !model.isExpanded, expandWork == nil else { return }
            withAnimation(reduceMotion ? nil : NQMotion.expand) { model.isExpanded = true }
        } else {
            expandWork?.cancel(); expandWork = nil
            guard model.isExpanded, foldWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withAnimation(self.reduceMotion ? nil : NQMotion.expand) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                    self.model.isHoveringSettings = false
                }
                self.setPointing(false)
                self.foldWork = nil
            }
            foldWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + NQTiming.foldGrace, execute: w)    // 0.45
        }
    }

    private func togglePin() {
        model.isPinned.toggle()
        if model.isPinned { withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.expand) { model.isExpanded = true } }
    }
    func refreshNow() { coordinator?.refreshAll() }


    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
        cursorTimer?.invalidate()
        if let w = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(w) }
    }
}
