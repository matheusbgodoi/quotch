import SwiftUI

/// Contas do MESMO provedor viram uma pilha de cartas: a da frente mostra o anel,
/// as de trás ficam deslocadas/escaladas atrás. Girar a pilha traz a próxima.
struct ProviderStack: Identifiable, Equatable {
    let kind: ProviderKind
    var accounts: [AccountSlot]
    var frontIndex: Int
    var id: ProviderKind { kind }
    var count: Int { accounts.count }
    var front: AccountSlot { accounts[min(max(frontIndex, 0), accounts.count - 1)] }
    /// Profundidade de cada conta: 0 = frente, 1 = logo atrás…
    func depth(of i: Int) -> Int { (i - frontIndex + accounts.count) % accounts.count }
}

extension NotchModel {
    /// Agrupa por provedor na ordem da primeira aparição.
    var stacks: [ProviderStack] {
        var order: [ProviderKind] = []
        var by: [ProviderKind: [AccountSlot]] = [:]
        for s in slots {
            if by[s.kind] == nil { order.append(s.kind); by[s.kind] = [] }
            by[s.kind]!.append(s)
        }
        return order.map { k in
            let a = by[k]!
            return ProviderStack(kind: k, accounts: a, frontIndex: min(frontIndex[k] ?? 0, a.count - 1))
        }
    }
    func cycle(_ kind: ProviderKind, by step: Int = 1) {
        guard let st = stacks.first(where: { $0.kind == kind }), st.count > 1 else { return }
        let n = st.count
        frontIndex[kind] = ((st.frontIndex + step) % n + n) % n
    }
}

/// Uma pilha desenhada: anéis em camadas + rótulo da conta da frente + pontinhos.
struct StackCell: View, Equatable {
    let stack: ProviderStack
    let isHovered: Bool
    let reduceMotion: Bool
    var metrics: StripMetrics = .full
    var refreshToken: Int = 0

    static func == (a: StackCell, b: StackCell) -> Bool {
        a.stack == b.stack && a.isHovered == b.isHovered && a.refreshToken == b.refreshToken
            && a.reduceMotion == b.reduceMotion && a.metrics == b.metrics
    }

    private func fraction(_ s: AccountSlot) -> Double? {
        switch s.state {
        case .reading(let f, _), .stale(let f): return f
        case .noData: return nil
        }
    }
    private func isStale(_ s: AccountSlot) -> Bool { if case .stale = s.state { return true }; return false }
    private func weekly(_ s: AccountSlot) -> Double? { if case .reading(_, let w) = s.state { return w }; return nil }

    /// Cartas atrás: menores, mais para cima, mais apagadas — como um baralho visto de frente.
    private func layer(_ s: AccountSlot, depth: Int) -> some View {
        let d = CGFloat(depth)
        let inner = metrics.ringDiameter - NQ.trackLineWidth
        return ZStack {
            Circle().stroke(NQ.track, lineWidth: NQ.trackLineWidth)
                .frame(width: inner, height: inner)
                .background(Circle().fill(NQ.body).frame(width: inner + NQ.trackLineWidth,
                                                          height: inner + NQ.trackLineWidth))
            // Anel de fora = janela curta (sessão/diário). Anel de dentro = semanal.
            RingArc(fraction: fraction(s) ?? 0)
                .stroke(style: StrokeStyle(lineWidth: NQ.arcLineWidth, lineCap: .round))
                .foregroundStyle(NQ.band(fraction(s) ?? 0))
                .frame(width: inner, height: inner)
                .refreshSpin(token: depth == 0 ? refreshToken : 0, reduceMotion: reduceMotion)
            if depth == 0, let wk = weekly(s) {
                RingArc(fraction: wk)
                    .stroke(style: StrokeStyle(lineWidth: NQ.arcLineWidth - 0.6, lineCap: .round))
                    .foregroundStyle(NQ.band(wk))
                    .frame(width: inner - 2 * NQ.arcLineWidth - 2, height: inner - 2 * NQ.arcLineWidth - 2)
            }
            if depth == 0 { Glyph(kind: s.kind) }
            if depth == 0, s.isActive { ActivitySpinner(active: true) }
        }
        .frame(width: metrics.ringDiameter, height: metrics.ringDiameter)
        .compositingGroup()
        .opacity(depth == 0 ? (isStale(s) ? NQ.staleOpacity : 1) : max(0.22, 0.5 - 0.18 * (d - 1)))
        .scaleEffect(1 - 0.12 * d, anchor: .top)
        .offset(y: -5 * d)
        .zIndex(Double(stack.count - depth))
    }

    var body: some View {
        let front = stack.front
        let f = fraction(front)
        VStack(spacing: 0) {
            ZStack {
                ForEach(Array(stack.accounts.enumerated()), id: \.element.id) { i, s in
                    layer(s, depth: stack.depth(of: i))
                }
            }
            .frame(width: metrics.ringDiameter, height: metrics.ringDiameter)
            .scaleEffect(isHovered ? NQMotion.hoverScaleFactor : 1.0, anchor: .center)
            .animation(NQMotion.gated(NQMotion.hoverScale, reduceMotion), value: isHovered)
            .animation(NQMotion.gated(NQMotion.flip, reduceMotion), value: stack.frontIndex)

            Spacer(minLength: 0)

            if metrics.showsPercent {
                Group {
                    if let f {
                        Text("\(Int((f * 100).rounded()))%")
                            .font(NQ.percentFont).monospacedDigit()
                            .foregroundStyle(NQ.onSurface)
                            .contentTransition(.numericText())
                    } else {
                        Capsule().fill(NQ.onSurface).frame(width: 12, height: 2)
                    }
                }
                .frame(height: 14)
                .opacity(isStale(front) ? NQ.staleOpacity : 1)
                .animation(NQMotion.gated(NQMotion.value, reduceMotion), value: f)
            }

            if stack.count > 1 {
                // Indicador de posição — também é o botão que gira a pilha.
                HStack(spacing: 3) {
                    ForEach(0..<stack.count, id: \.self) { i in
                        Circle().fill(NQ.onSurface.opacity(i == stack.frontIndex ? 0.95 : 0.32))
                            .frame(width: 3.5, height: 3.5)
                    }
                }
                .frame(height: 10)
                .padding(.top, 2)
                .animation(NQMotion.gated(NQMotion.flip, reduceMotion), value: stack.frontIndex)
            }
        }
        .frame(width: NQ.stripThickness,
               height: metrics.ringDiameter + (metrics.showsPercent ? 27.5 : 0) + (stack.count > 1 ? 12 : 0))
    }
}
