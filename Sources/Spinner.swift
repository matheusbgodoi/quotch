import SwiftUI

/// Indicador de "buscando agora". Enquanto `active` for false o TimelineView fica
/// PAUSADO — e a diferenca entre 0,3% e 7,5% de CPU em repouso.
struct ActivitySpinner: View {
    var active: Bool
    var diameter: CGFloat = NQ.ringRadius * 2

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (t / NQMotion.spinPeriod).truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(style: StrokeStyle(lineWidth: NQ.arcLineWidth, lineCap: .round))
                .foregroundStyle(NQ.onSurface.opacity(0.85))
                .rotationEffect(.degrees(-90 + phase * 360))
                .frame(width: diameter, height: diameter)
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: NQMotion.windowFade), value: active)
        .allowsHitTesting(false)
    }
}

/// Giro unico de 360 graus quando um refresh conclui (campo `_spin` de referência,
/// 0x100049ef8 — o closure faz literalmente State.wrappedValue += 360.0).
struct RefreshSpinModifier: ViewModifier {
    let token: Int          // incrementa a cada leitura nova daquele slot
    let reduceMotion: Bool
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onChange(of: token) { _, _ in
                withAnimation(NQMotion.gated(NQMotion.refreshSpin, reduceMotion)) {
                    angle += 360      // += e nao =, para nao "desgirar" no segundo refresh
                }
            }
    }
}

extension View {
    func refreshSpin(token: Int, reduceMotion: Bool) -> some View {
        modifier(RefreshSpinModifier(token: token, reduceMotion: reduceMotion))
    }
}