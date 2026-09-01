import SwiftUI

struct QuotaWindow: Identifiable {
    let id = UUID()
    var label: String       // "Current session", "All models", "Weekly limit"
    var resetText: String   // "Resets Tue 14:49"
    var fraction: Double
}

struct HoverCard: View {
    let slot: AccountSlot
    let windows: [QuotaWindow]
    let sessionTitle: String?, sessionSubtitle: String?
    let sessionStatus: String?, sessionAge: String?
    /// Posição vertical do bico dentro do cartão (nil = centro).
    var beakY: CGFloat? = nil
    var beakEdge: NotchEdge = .right

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Glyph(kind: slot.kind, size: 17)
                Text({ let who = slot.nickname.isEmpty ? (slot.displayName ?? "") : slot.nickname; return who.isEmpty ? slot.kind.displayName : "\(slot.kind.displayName) · \(who)" }())
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NQ.onSurface)
            }
            .padding(.bottom, 10)

            ForEach(windows, id: \.id) { (w: QuotaWindow) in
                HStack {
                    Text(w.label).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NQ.onSurface)
                    Spacer(minLength: 12)
                    Text(w.resetText).font(.system(size: 12))
                        .foregroundStyle(NQ.secondary)          // #808080
                }
                .padding(.bottom, 8)

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NQ.barTrack)             // #2D2D2D
                        Capsule().fill(NQ.band(w.fraction))
                            .frame(width: max(0, g.size.width * w.fraction))
                    }
                }
                .frame(height: 4)
                .padding(.bottom, 9)

                Text("\(Int((w.fraction * 100).rounded()))% Used")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NQ.onSurface)
                    .padding(.bottom, w.id == windows.last?.id ? 9.5 : 11)
            }

            if let t = sessionTitle {
                Rectangle().fill(NQ.track).frame(height: 0.5)   // #303030
                    .padding(.bottom, 10)
                HStack {
                    Text(t).font(.system(size: 12)).foregroundStyle(NQ.onSurface)
                    Spacer(minLength: 12)
                    if let s = sessionStatus {
                        Label(s, systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NQ.ample)          // #00FF88
                            .labelStyle(.titleAndIcon)
                    }
                }
                HStack {
                    Text(sessionSubtitle ?? "").font(.system(size: 12))
                    Spacer(minLength: 12)
                    Text(sessionAge ?? "").font(.system(size: 12))
                }
                .foregroundStyle(NQ.secondary)
                .padding(.top, 5.5)
            }
        }
        .padding(.horizontal, 12.5)
        .padding(.top, 12.5)
        .padding(.bottom, 14)
        .frame(width: NQ.hoverCardWidth, alignment: .leading)
        .background(CardWithBeak(beakY: beakY, beakEdge: beakEdge).fill(NQ.body))
    }
}

/// Retângulo arredondado + bico à direita, centrado verticalmente.
struct CardWithBeak: Shape {
    var radius: CGFloat = 16
    var beakY: CGFloat? = nil          // posição do bico ao longo da borda do cartão
    var beakEdge: NotchEdge = .right   // para que lado da faixa o bico aponta
    var beakLength: CGFloat = 27.5
    var beakHeight: CGFloat = 32
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
        var b = Path()
        let h = beakHeight / 2
        switch beakEdge {
        case .right:
            let cy = beakY.map { min(max($0, h + 12), r.height - h - 12) } ?? r.midY
            b.move(to: CGPoint(x: r.maxX - 1, y: cy - h)); b.addLine(to: CGPoint(x: r.maxX + beakLength, y: cy)); b.addLine(to: CGPoint(x: r.maxX - 1, y: cy + h))
        case .left:
            let cy = beakY.map { min(max($0, h + 12), r.height - h - 12) } ?? r.midY
            b.move(to: CGPoint(x: r.minX + 1, y: cy - h)); b.addLine(to: CGPoint(x: r.minX - beakLength, y: cy)); b.addLine(to: CGPoint(x: r.minX + 1, y: cy + h))
        case .top:
            let cx = beakY.map { min(max($0, h + 12), r.width - h - 12) } ?? r.midX
            b.move(to: CGPoint(x: cx - h, y: r.minY + 1)); b.addLine(to: CGPoint(x: cx, y: r.minY - beakLength)); b.addLine(to: CGPoint(x: cx + h, y: r.minY + 1))
        case .bottom:
            let cx = beakY.map { min(max($0, h + 12), r.width - h - 12) } ?? r.midX
            b.move(to: CGPoint(x: cx - h, y: r.maxY - 1)); b.addLine(to: CGPoint(x: cx, y: r.maxY + beakLength)); b.addLine(to: CGPoint(x: cx + h, y: r.maxY - 1))
        }
        b.closeSubpath()
        p.addPath(b)
        return p
    }
}

// Ancoragem no NotchRootView (ZStack alinhado à direita, largura 335):
// .offset(x: -(NQ.panelWidth + NQ.hoverCardGap + 27.5),
//         y: ringCenterY(of: hoveredIndex) - geo.size.height / 2)
// e a card inteira com .opacity(model.hoveredIndex == nil ? 0 : 1)
//                     .animation(NQ.springHover, value: model.hoveredIndex)
//                     .animation(NQ.fade, value: model.hoveredIndex == nil)