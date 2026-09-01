import SwiftUI

/// Silhueta da faixa. Cada ponta = dois arcos tangentes (é o que o binário do
/// the reference notch app faz: move + 4×addArc + 3×addLine): um filete CÔNCAVO de raio `curl`
/// tangente à borda da tela — a peça fica fina por ~30 pt — e um canto CONVEXO
/// de raio `corner` que abre para a lateral reta. Perfil medido em
/// docs/design-tokens.md; os arcos são amostrados em segmentos para não depender
/// da convenção de sentido do `addArc`.
struct SideNotchShape: Shape {
    var edge: NotchEdge
    var thickness: CGFloat
    var length: CGFloat
    var curl: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(thickness, length), .init(curl, corner)) }
        set {
            thickness = newValue.first.first
            length    = newValue.first.second
            curl      = newValue.second.first
            corner    = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let box = edge.isVertical ? rect
                                  : CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
        var p = canonical(in: box)
        switch edge {
        case .right: break
        case .left:
            p = p.applying(CGAffineTransform(scaleX: -1, y: 1)
                            .concatenating(CGAffineTransform(translationX: rect.width, y: 0)))
        case .top:
            p = p.applying(CGAffineTransform(rotationAngle: -.pi / 2)
                            .concatenating(CGAffineTransform(translationX: 0, y: box.width)))
        case .bottom:
            p = p.applying(CGAffineTransform(rotationAngle: .pi / 2)
                            .concatenating(CGAffineTransform(translationX: box.height, y: 0)))
        }
        return p
    }

    /// Pontos da ponta de cima, do bico (na borda) até o início da lateral reta.
    private func topEnd(xE: CGFloat, xI: CGFloat, yT: CGFloat, W: CGFloat) -> [CGPoint] {
        let rk = max(min(curl, W * 4), 0.01)
        let rc = max(min(corner, W / 2), 0.01)
        let c1 = CGPoint(x: xE - rk, y: yT)                 // centro do filete côncavo
        let dx = rk + rc - W                                 // c2.x - c1.x
        let dy = max((rk + rc) * (rk + rc) - dx * dx, 0).squareRoot()
        let c2 = CGPoint(x: xI + rc, y: yT + dy)             // centro do canto convexo
        let phi = atan2(dy, dx)                              // ângulo do ponto de tangência
        var pts: [CGPoint] = []
        let n = 18
        for i in 0...n {                                     // côncavo: de 0 até phi
            let a = phi * CGFloat(i) / CGFloat(n)
            pts.append(CGPoint(x: c1.x + rk * cos(a), y: c1.y + rk * sin(a)))
        }
        for i in 1...n {                                     // convexo: de phi+π até π
            let a = (phi + .pi) - phi * CGFloat(i) / CGFloat(n)
            pts.append(CGPoint(x: c2.x + rc * cos(a), y: c2.y + rc * sin(a)))
        }
        return pts
    }

    private func canonical(in rect: CGRect) -> Path {
        let W = max(min(thickness, rect.width), 0.5)
        let L = max(min(length, rect.height), 2)
        let xE = rect.maxX
        let xI = xE - W
        let yT = rect.midY - L / 2
        let yB = yT + L
        let top = topEnd(xE: xE, xI: xI, yT: yT, W: W)
        // Espelha para a ponta de baixo.
        let bottom = top.reversed().map { CGPoint(x: $0.x, y: yB - ($0.y - yT)) }
        var p = Path()
        p.move(to: top[0])
        for q in top.dropFirst() { p.addLine(to: q) }
        for q in bottom { p.addLine(to: q) }
        p.closeSubpath()
        return p
    }
}

extension SideNotchShape {
    static func collapsed(_ edge: NotchEdge) -> SideNotchShape {
        .init(edge: edge, thickness: NQGeo.pillThickness, length: NQGeo.pillLength,
              curl: NQGeo.pillCurlRadius, corner: NQGeo.pillCornerRadius)
    }
    static func expanded(_ edge: NotchEdge, contentLength: CGFloat) -> SideNotchShape {
        .init(edge: edge, thickness: NQGeo.stripThickness, length: contentLength,
              curl: NQGeo.curlRadius, corner: NQGeo.cornerRadius)
    }
}
