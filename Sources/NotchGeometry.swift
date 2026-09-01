import AppKit

// MARK: - Borda da faixa

// NotchEdge vive em Config.swift (é persistido). Só a conveniência de layout mora aqui.
extension NotchEdge {
    var isVertical: Bool { self == .left || self == .right }
}

// MARK: - Escolha de tela (multi-monitor)

enum ScreenChoice: Equatable {
    case primary                      // tela da barra de menus — padrao
    case withNotch                    // primeira com notch fisica
    case display(CGDirectDisplayID)   // fixada pelo usuario nas Settings

    func resolve() -> NSScreen? {
        let all = NSScreen.screens
        guard let primary = all.first else { return nil }
        switch self {
        case .primary:  return primary
        case .withNotch: return all.first { $0.safeAreaInsets.top > 0 } ?? primary
        case .display(let id): return all.first { $0.nq_displayID == id } ?? primary
        }
    }
}

extension NSScreen {
    /// NSScreen nao e estavel entre reconfiguracoes; guarde o displayID, nunca o objeto.
    var nq_displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var nq_hasHardwareNotch: Bool {
        guard let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea else { return false }
        return (frame.width - l.width - r.width) > 0 && safeAreaInsets.top > 0
    }
}

// MARK: - Metricas do DESENHO (nao da janela)

struct StripMetrics: Equatable {
    var pitch: CGFloat
    var ringDiameter: CGFloat
    var showsPercent: Bool
    var leadPad: CGFloat
    var trailPad: CGFloat

    /// Metrica de referência: L(n) = 91,05 + n*102,50 (binario 0x10003bd40 + panel.png).
    static let full  = StripMetrics(pitch: 102.5, ringDiameter: 44, showsPercent: true,
                                    leadPad: 46.25, trailPad: 44.80)
    /// Sem rotulo de %: o numero volta no hover, o arco continua legivel.
    static let dense = StripMetrics(pitch: 70.0, ringDiameter: 44, showsPercent: false,
                                    leadPad: 30, trailPad: 30)
    /// Ultimo degrau antes de cortar: anel menor.
    static let tiny  = StripMetrics(pitch: 52.0, ringDiameter: 34, showsPercent: false,
                                    leadPad: 24, trailPad: 24)

    /// Fracao do espaco util que cada degrau aceita ocupar. `full` so vale enquanto a faixa
    /// nao domina a tela — e o que impede a sensacao de "esta vazando" com 8-9 contas.
    static let ladder: [(metrics: StripMetrics, comfort: CGFloat)] =
        [(.full, 0.72), (.dense, 0.90), (.tiny, 1.0)]

    /// Linha da engrenagem (26 pt) no fim da faixa.
    static let gearRow: CGFloat = 44 + 14
    func stripLength(for n: Int) -> CGFloat {
        leadPad + CGFloat(max(n, 0)) * pitch + StripMetrics.gearRow + trailPad
    }
    func capacity(in available: CGFloat) -> Int {
        max(Int(((available - leadPad - trailPad - StripMetrics.gearRow) / pitch).rounded(.down)), 0)
    }
}

// MARK: - Resultado

struct NotchLayout: Equatable {
    var windowFrame: NSRect      // frame da JANELA (maior que o desenho)
    var metrics: StripMetrics    // densidade escolhida
    var visibleCount: Int        // slots desenhados
    var overflowCount: Int       // slots que viraram chip "+N"
    var stripLength: CGFloat     // comprimento do DESENHO
    var stripThickness: CGFloat  // 70
    var edge: NotchEdge
    var screenID: CGDirectDisplayID
}

// MARK: - Motor

enum NotchLayoutEngine {
    /// Espessura do desenho — 70 pt medidos no app de referência.
    static let stripThickness: CGFloat = 70
    /// Folga transversal da JANELA (264,376068 no binario): espaco para o hover abrir.
    static let slackCross: CGFloat = 264.4
    /// Folga em cada ponta do eixo longo (71,452991 no binario).
    static let slackLong: CGFloat = 71.45
    /// Respiro contra barra de menus / Dock.
    static let edgeMargin: CGFloat = 12

    static func layout(slots n: Int, edge: NotchEdge, on screen: NSScreen) -> NotchLayout {
        let f = screen.frame
        let v = screen.visibleFrame

        // 1. faixa util no eixo LONGO — nunca a barra de menus, nunca o Dock
        let longMin: CGFloat, longMax: CGFloat
        if edge.isVertical {
            longMin = v.minY + edgeMargin
            longMax = min(v.maxY, f.maxY - screen.safeAreaInsets.top) - edgeMargin
        } else {
            longMin = v.minX + edgeMargin
            longMax = v.maxX - edgeMargin
        }
        let available = max(longMax - longMin, stripThickness)

        // 2. escada de densidade
        var metrics = StripMetrics.full
        var shown = n
        var overflow = 0
        var fitted = false
        for step in StripMetrics.ladder {
            metrics = step.metrics
            if step.metrics.stripLength(for: n) <= available * step.comfort {
                shown = n; overflow = 0; fitted = true; break
            }
        }
        if !fitted {                       // nem no degrau mais compacto cabe: corta
            let cap = metrics.capacity(in: available)
            shown = max(cap - 1, 1)        // 1 celula reservada ao chip "+N"
            overflow = max(n - shown, 0)
        }

        // 3. desenho e janela
        let drawn = shown + (overflow > 0 ? 1 : 0)
        let stripLen = min(metrics.stripLength(for: drawn), available)
        let winLong  = ceil(stripLen + 2 * slackLong)      // ceil = frintp de referência
        let winCross = ceil(stripThickness + slackCross)

        // 4. centro do DESENHO: midY fisico, clampado na faixa util
        var center = edge.isVertical ? f.midY : f.midX
        center = min(center, longMax - stripLen / 2)
        center = max(center, longMin + stripLen / 2)

        var rect: NSRect
        switch edge {
        case .right:
            rect = NSRect(x: v.maxX - winCross, y: center - winLong / 2, width: winCross, height: winLong)
        case .left:
            rect = NSRect(x: v.minX, y: center - winLong / 2, width: winCross, height: winLong)
        case .top:
            let top = screen.nq_hasHardwareNotch ? f.maxY : v.maxY
            rect = NSRect(x: center - winLong / 2, y: top - winCross, width: winLong, height: winCross)
        case .bottom:
            rect = NSRect(x: center - winLong / 2, y: v.minY, width: winLong, height: winCross)
        }
        rect.origin.x.round()   // round = frinta de referência
        rect.origin.y.round()

        return NotchLayout(windowFrame: rect, metrics: metrics, visibleCount: shown,
                           overflowCount: overflow, stripLength: stripLen,
                           stripThickness: stripThickness, edge: edge,
                           screenID: screen.nq_displayID)
    }
}