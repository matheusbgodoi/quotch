import SwiftUI

/// Arco do anel como Shape com `animatableData` proprio: e isto que faz o
/// percentual deslizar do valor velho para o novo em vez de pular.
struct RingArc: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let f = min(max(fraction, 0), 1)
        guard f > 0.0005 else { return p }
        let radius = min(r.width, r.height) / 2
        p.addArc(center: CGPoint(x: r.midX, y: r.midY),
                 radius: radius,
                 startAngle: .degrees(-90),
                 endAngle: .degrees(-90 + 360 * f),
                 clockwise: false)
        return p
    }
}

struct RingCell: View, Equatable {
    let slot: AccountSlot
    let isHovered: Bool
    let reduceMotion: Bool
    var metrics: StripMetrics = .full

    // == manual: o sintetizado nao sai porque a struct tem @State.
    static func == (a: RingCell, b: RingCell) -> Bool {
        a.slot == b.slot && a.isHovered == b.isHovered
            && a.reduceMotion == b.reduceMotion && a.metrics == b.metrics
    }

    @State private var lastPercent: Int = 0

    private var fraction: Double? {
        switch slot.state {
        case .reading(let f, _), .stale(let f): return f
        case .noData: return nil
        }
    }
    private var isStale: Bool { if case .stale = slot.state { return true }; return false }
    private var percent: Int { Int(((fraction ?? 0) * 100).rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .stroke(NQ.track, lineWidth: NQ.trackLineWidth)
                    .frame(width: metrics.ringDiameter - NQ.trackLineWidth,
                           height: metrics.ringDiameter - NQ.trackLineWidth)

                RingArc(fraction: fraction ?? 0)
                    .stroke(style: StrokeStyle(lineWidth: NQ.arcLineWidth, lineCap: .round))
                    .foregroundStyle(NQ.band(fraction ?? 0))   // foregroundStyle interpola; stroke(Color) nao
                    .frame(width: metrics.ringDiameter - NQ.trackLineWidth,
                           height: metrics.ringDiameter - NQ.trackLineWidth)

                Glyph(kind: slot.kind)
            }
            .frame(width: metrics.ringDiameter, height: metrics.ringDiameter)
            .scaleEffect(isHovered ? NQMotion.hoverScaleFactor : 1.0, anchor: .center)
            .animation(NQMotion.gated(NQMotion.hoverScale, reduceMotion), value: isHovered)

            Spacer(minLength: 0)

            Group {
                if !metrics.showsPercent {
                    EmptyView()
                } else if fraction != nil {
                    Text("\(percent)%")
                        .font(NQ.percentFont)
                        .monospacedDigit()
                        .foregroundStyle(NQ.onSurface)
                        .contentTransition(.numericText(countsDown: percent < lastPercent))
                } else {
                    Capsule().fill(NQ.onSurface).frame(width: 12, height: 2)
                        .transition(.opacity)
                }
            }
            .frame(height: metrics.showsPercent ? 14 : 0)
        }
        .frame(width: NQ.stripThickness,
               height: metrics.ringDiameter + (metrics.showsPercent ? 27.5 : 0))
        .compositingGroup()                       // opacity de grupo, sem blend duplo
        .opacity(isStale ? NQ.staleOpacity : 1)
        .animation(NQMotion.gated(NQMotion.stale, reduceMotion), value: isStale)
        .animation(NQMotion.gated(NQMotion.value, reduceMotion), value: fraction)
        .onChange(of: percent) { _, novo in lastPercent = novo }
        .onAppear { lastPercent = percent }
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    let layout: NotchLayout
    var onRects: ([CGRect]) -> Void = { _ in }
    var onGearRect: (CGRect) -> Void = { _ in }
    var showEmails: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardHeight: CGFloat = 140

    private var shown: ArraySlice<ProviderStack> { model.stacks.prefix(layout.visibleCount) }
    /// Densidade efetiva: respeita o toggle "Show percentages".
    private var effectiveMetrics: StripMetrics {
        var m = layout.metrics; if !model.showPercentages { m.showsPercent = false }; return m
    }
    /// Com "Group by kind", abre um respiro antes da 1ª conta de generation.
    private func groupBreak(before idx: Int) -> Bool {
        guard model.groupByCategory, idx > 0 else { return false }
        let a = Array(shown)
        return a[idx-1].kind.category == .coding && a[idx].kind.category == .generation
    }
    private var orderKey: [UUID] { model.slots.map(\.id) }
    private var expanded: Bool { model.isExpanded }
    private var gearShown: Bool { expanded && model.isHoveringSettings }
    /// Comprimento desenhado: sem hover a linha da engrenagem fica "atrás" da ponta.
    private var drawnLength: CGFloat { layout.stripLength - (gearShown ? 0 : StripMetrics.gearRow) }

    // A faixa desenhada. Colapsada vira a pilula — MESMO Shape, outra espessura.
    @ViewBuilder private func cell(_ idx: Int, _ stack: ProviderStack) -> some View {
        StackCell(stack: stack,
                  isHovered: model.hoveredIndex == idx,
                  reduceMotion: reduceMotion,
                  metrics: effectiveMetrics,
                  refreshToken: model.refreshToken[stack.front.id] ?? 0)
            .equatable()
            .padding(.top, groupBreak(before: idx) ? 12 : 0)
            .frame(width: layout.edge.isVertical ? nil : layout.metrics.pitch,
                   height: layout.edge.isVertical ? layout.metrics.pitch : nil)
            .geometryGroup()
            .opacity(expanded ? 1 : 0)
            .scaleEffect(expanded ? 1 : 0.55, anchor: layout.edge.anchor)
            .offset(x: expanded ? 0 : layout.edge.pushOut.width, y: expanded ? 0 : layout.edge.pushOut.height)
            .animation(NQMotion.gated(expanded ? NQMotion.entrance(index: idx) : NQMotion.remove, reduceMotion), value: expanded)
            .background(GeometryReader { g in
                Color.clear.preference(key: RectsKey.self, value: [RectItem(index: idx, rect: g.frame(in: .named("notch")))])
            })
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.86, anchor: .center))
                    .animation(NQMotion.gated(NQMotion.entrance(index: idx), reduceMotion)),
                removal: .opacity.combined(with: .scale(scale: 0.90, anchor: .center))
                    .animation(NQMotion.gated(NQMotion.remove, reduceMotion))))
    }

    private var strip: some View {
        AxisStack(vertical: layout.edge.isVertical) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, stack in
                cell(idx, stack)
            }
            if layout.overflowCount > 0 {
                OverflowChip(count: layout.overflowCount).frame(height: layout.metrics.pitch)
            }
            // Engrenagem de referência: botão redondo escondido atrás da ponta; no hover a
            // faixa cresce para baixo e o círculo aparece.
            GearButton(highlight: model.isHoveringSettings)
                .frame(width: layout.edge.isVertical ? nil : StripMetrics.gearRow,
                       height: layout.edge.isVertical ? StripMetrics.gearRow : nil,
                       alignment: layout.edge.isVertical ? .top : .leading)
                .opacity(gearShown ? 1 : 0)
                .scaleEffect(gearShown ? 1 : 0.35, anchor: .top)
                .animation(NQMotion.gated(NQMotion.reveal, reduceMotion), value: gearShown)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: GearKey.self, value: g.frame(in: .named("notch")))
                    }
                )
        }
        .padding(layout.edge.isVertical ? .top : .leading, layout.metrics.leadPad)
        .padding(layout.edge.isVertical ? .bottom : .trailing, layout.metrics.trailPad)
        .frame(width: layout.edge.isVertical ? layout.stripThickness : layout.stripLength,
               height: layout.edge.isVertical ? layout.stripLength : layout.stripThickness,
               alignment: layout.edge.isVertical ? .top : .leading)
        // Recorta pelo mesmo Shape da faixa (no comprimento desenhado): nada vaza, nunca.
        .clipShape(SideNotchShape.expanded(layout.edge, contentLength: drawnLength)
                    .offset(x: layout.edge.isVertical ? 0 : -(layout.stripLength - drawnLength) / 2,
                            y: layout.edge.isVertical ? -(layout.stripLength - drawnLength) / 2 : 0))
        .animation(NQMotion.gated(NQMotion.reveal, reduceMotion), value: gearShown)
        .opacity(expanded ? 1 : 0)
        .allowsHitTesting(expanded)
    }

    var body: some View {
        realBody
    }

    private var realBody: some View {
        // A JANELA e maior que o desenho: a folga transversal existe para o cartao
        // de hover nao ser recortado, e e click-through.
        AxisStack(vertical: !layout.edge.isVertical) {
            if layout.edge == .right || layout.edge == .bottom { Spacer(minLength: 0) }
            ZStack(alignment: layout.edge.alignment) {
                if !(model.visibility == .hidden && !model.isPinned) {
                    // O MESMO Shape nos dois estados: os parâmetros animam (morph),
                    // como o the reference notch app faz com a SideNotchShape.
                    (expanded ? SideNotchShape.expanded(layout.edge, contentLength: drawnLength)
                              : SideNotchShape.collapsed(layout.edge))
                        .fill(NQ.body)
                        .frame(width: layout.edge.isVertical ? layout.stripThickness : (expanded ? drawnLength : NQ.pillLength),
                               height: layout.edge.isVertical ? (expanded ? drawnLength : NQ.pillLength) : layout.stripThickness)
                        .frame(width: layout.edge.isVertical ? nil : layout.stripLength,
                               height: layout.edge.isVertical ? layout.stripLength : nil,
                               alignment: expanded ? (layout.edge.isVertical ? .top : .leading) : .center)
                        .animation(NQMotion.gated(NQMotion.reveal, reduceMotion), value: gearShown)
                    strip
                }
            }
            if layout.edge == .left || layout.edge == .top { Spacer(minLength: 0) }
        }
        .frame(width: layout.windowFrame.width, height: layout.windowFrame.height)
        .overlay(alignment: layout.edge == .right ? .topTrailing : .topLeading) { hoverCard }
        .coordinateSpace(name: "notch")
        .onPreferenceChange(RectsKey.self) { items in
            onRects(items.sorted { $0.index < $1.index }.map(\.rect))
        }
        .onPreferenceChange(GearKey.self) { onGearRect($0) }
        .onPreferenceChange(CardHeightKey.self) { if $0 > 0 { cardHeight = $0 } }
        .animation(NQMotion.gated(NQMotion.reorder, reduceMotion), value: orderKey)
        .animation(NQMotion.gated(NQMotion.hoverEnter, reduceMotion), value: model.hoveredIndex)
        .animation(NQMotion.gated(NQMotion.expand, reduceMotion), value: expanded)
    }
}

extension NotchRootView {
    /// Cartão de detalhe de referência: 226 pt à esquerda da faixa, bico apontando
    /// para o centro do anel. Some com o hover, entra com o spring hoverEnter.
    @ViewBuilder var hoverCard: some View {
        if expanded, let i = model.hoveredIndex, i < model.stacks.count {
            let stack = model.stacks[i]
            let slot = stack.front
            let vertical = layout.edge.isVertical
            let stripStart = ((vertical ? layout.windowFrame.height : layout.windowFrame.width) - layout.stripLength) / 2
            let ringCenter = stripStart + layout.metrics.leadPad
                + CGFloat(i) * layout.metrics.pitch + layout.metrics.ringDiameter / 2
            let ringCenterY = ringCenter
            let cardTop = vertical ? min(max(ringCenter - cardHeight / 2, 8), layout.windowFrame.height - cardHeight - 8)
                                   : (layout.edge == .top ? layout.stripThickness + 10 : layout.windowFrame.height - layout.stripThickness - 10 - cardHeight)
            let cardLeft: CGFloat = vertical ? (layout.edge == .right ? -(layout.stripThickness + 10) : layout.stripThickness + 10)
                                             : min(max(ringCenter - NQ.hoverCardWidth / 2, 8), layout.windowFrame.width - NQ.hoverCardWidth - 8)
            HoverCard(slot: slot,
                      windows: model.readings[slot.id]?.windows ?? NotchRootView.demoWindows(for: slot),
                      sessionTitle: QuotchDemo ? slot.plan : [model.showEmails ? slot.email : slot.displayName, slot.plan].compactMap { $0 }.joined(separator: " · "),
                      sessionSubtitle: [stack.count > 1 ? "Account \(stack.frontIndex + 1) of \(stack.count) · scroll or tap the dots to switch" : nil, Vault.has(slot.id) ? "Reads with the login captured for this account" : nil].compactMap { $0 }.joined(separator: "\n"),
                      sessionStatus: nil, sessionAge: nil,
                      beakY: vertical ? ringCenterY - cardTop : ringCenter - cardLeft,
                      beakEdge: layout.edge)
                .background(GeometryReader { g in
                    Color.clear.preference(key: CardHeightKey.self, value: g.size.height)
                })
                .offset(x: vertical && layout.edge == .right ? cardLeft : 0, y: cardTop)
                .offset(x: vertical && layout.edge == .right ? 0 : cardLeft)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                .id(slot.id)
                .animation(NQMotion.gated(NQMotion.hoverEnter, reduceMotion), value: slot.id)
        }
    }

    static func demoWindows(for slot: AccountSlot) -> [QuotaWindow] {
        let f: Double = { if case .reading(let v, _) = slot.state { return v }
                          if case .stale(let v) = slot.state { return v }; return 0 }()
        switch slot.kind {
        case .claude: return [QuotaWindow(label: "Current session", resetText: "Resets in 3 hr 37 min", fraction: f),
                              QuotaWindow(label: "All models", resetText: "Resets Tue 14:49", fraction: f * 0.6),
                              QuotaWindow(label: "Fable", resetText: "Resets Tue 14:49", fraction: f * 0.3)]
        case .codex:  return [QuotaWindow(label: "Current session", resetText: "Resets in 2 hr", fraction: f),
                              QuotaWindow(label: "Weekly limit", resetText: "Resets Sat 09:00", fraction: f * 0.5)]
        case .cursor: return [QuotaWindow(label: "Included usage", resetText: "Resets 30 Sep", fraction: f)]
        case .antigravity: return [QuotaWindow(label: "Daily quota", resetText: "Resets 00:00", fraction: f)]
        case .flow:   return [QuotaWindow(label: "760 / 1000 monthly credits", resetText: "Monthly plan", fraction: f)]
        case .grok:   return [QuotaWindow(label: "Weekly limit", resetText: "Resets Sat 09:00", fraction: f)]
        }
    }
}

struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { let n = nextValue(); if n > 0 { value = n } }
}

struct GearButton: View {
    var highlight: Bool = false
    var body: some View {
        ZStack {
            Circle().stroke(NQ.track, lineWidth: NQ.trackLineWidth)
                .frame(width: NQ.ringRadius * 2, height: NQ.ringRadius * 2)
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(NQ.onSurface.opacity(highlight ? 1 : 0.85))
        }
        .frame(width: NQ.ringOuterDiameter, height: NQ.ringOuterDiameter)
        .scaleEffect(highlight ? 1.06 : 1)
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NQMotion.hoverScale, value: highlight)
            .frame(width: NQ.stripThickness)
    }
}

struct OverflowChip: View {
    let count: Int
    var body: some View {
        Text("+\(count)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(NQ.onSurface.opacity(0.7))
            .frame(width: NQ.stripThickness)
    }
}

struct RectItem: Equatable { let index: Int; let rect: CGRect }
struct RectsKey: PreferenceKey {
    static var defaultValue: [RectItem] = []
    static func reduce(value: inout [RectItem], nextValue: () -> [RectItem]) { value += nextValue() }
}
struct GearKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue(); if n != .zero { value = n }
    }
}


/// VStack ou HStack conforme a borda, com a mesma sintaxe.
struct AxisStack<Content: View>: View {
    let vertical: Bool
    @ViewBuilder let content: () -> Content
    init(vertical: Bool, @ViewBuilder content: @escaping () -> Content) { self.vertical = vertical; self.content = content }
    var body: some View {
        if vertical { VStack(spacing: 0, content: content) } else { HStack(spacing: 0, content: content) }
    }
}

extension NotchEdge {
    var alignment: Alignment {
        switch self { case .right: return .trailing; case .left: return .leading; case .top: return .top; case .bottom: return .bottom }
    }
    var anchor: UnitPoint {
        switch self { case .right: return .trailing; case .left: return .leading; case .top: return .top; case .bottom: return .bottom }
    }
    var pushOut: CGSize {
        switch self { case .right: return CGSize(width: 22, height: 0); case .left: return CGSize(width: -22, height: 0)
                      case .top: return CGSize(width: 0, height: -22); case .bottom: return CGSize(width: 0, height: 22) }
    }
}
