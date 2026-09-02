import SwiftUI

// ============================================================================
//  Glyphs.swift — marcas dos provedores, redesenhadas a partir da medição do
//  the reference notch app (panel.png @2x, docs/dissecacao). Uso nominativo: cada glifo
//  identifica a conta cuja cota está sendo mostrada.
//
//  Caixas medidas no app de referência (pt):
//    Claude       17 × 17     (33 × 33 px @2x)
//    OpenAI/Codex 15,75 × 15,75 dentro de caixa 17 (33 × 33 px de tinta)
//    Cursor       15 × 17     (29 × 33,5 px)
//    Antigravity  17 × 15,5   (34 × 31 px)
//    Flow         17 × 17     (proposto — não existe no app de referência)
// ============================================================================

// MARK: - Ponto de entrada

struct Glyph: View {
    let kind: ProviderKind
    var size: CGFloat = NQ.glyphSize          // 17 pt
    var color: Color = .white

    /// Caixa própria de cada marca, em pt para size = 17.
    private var box: CGSize {
        switch kind {
        case .cursor: return CGSize(width: size * 15 / 17, height: size)
        default:      return CGSize(width: size, height: size)
        }
    }

    var body: some View {
        ZStack {
            switch kind {
            case .claude:
                ClaudeGlyph().fill(color)
            case .codex:
                OpenAIGlyph().stroke(color, lineWidth: size * 0.8 / 17)
            case .cursor:
                CursorGlyph().fill(color, style: FillStyle(eoFill: true))
            case .antigravity:
                AntigravityGlyph().fill(color)
            case .flow:
                FlowGlyph().fill(color)
            case .grok:
                GrokGlyph().fill(color, style: FillStyle(eoFill: true))
            }
        }
        .frame(width: box.width, height: box.height)
        .frame(width: size, height: size)     // slot quadrado, marca centrada
    }
}

// MARK: - Claude (estrela / burst da Anthropic)
//
// 12 raios, ângulos e comprimentos IRREGULARES — medidos um a um em panel.png.
// Um burst de 12 raios igualmente espaçados marca erro médio 49/255 contra o
// original; estes valores marcam 17,8/255. Cada raio é um trapézio (base larga
// no centro, ponta arredondada), não um traço de espessura constante.

struct ClaudeGlyph: Shape {
    /// Ângulos em graus, 0 = 12 h, sentido horário.
    static let rayAngles: [CGFloat] = [
        16.85,  49.45,  85.55, 106.20, 131.18, 147.49,
       177.49, 204.01, 229.38, 266.85, 303.50, 338.02,
    ]
    /// Comprimento de cada raio como fração do raio da caixa (8,5 pt em 17 pt).
    static let rayLengths: [CGFloat] = [
        0.9026, 0.9665, 0.9813, 0.9951, 0.9685, 1.0000,
        0.9715, 0.8720, 0.8573, 0.8819, 0.9006, 0.9852,
    ]
    static let baseHalfWidth: CGFloat = 0.0982   // × R  (1,70 pt de base em 17 pt)
    static let tipRadius: CGFloat     = 0.0665   // × R  (1,15 pt de ponta)

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let wb = Self.baseHalfWidth * R
        let rt = Self.tipRadius * R
        var p = Path()
        for i in 0..<Self.rayAngles.count {
            let a = Double(Self.rayAngles[i] - 90) * .pi / 180
            let ux = CGFloat(cos(a)), uy = CGFloat(sin(a))
            let px = -uy, py = ux                      // perpendicular
            let L = Self.rayLengths[i] * R - rt        // centro da calota
            let tip = CGPoint(x: c.x + ux * L, y: c.y + uy * L)
            p.move(to: CGPoint(x: c.x + px * wb, y: c.y + py * wb))
            p.addLine(to: CGPoint(x: tip.x + px * rt, y: tip.y + py * rt))
            p.addLine(to: CGPoint(x: tip.x - px * rt, y: tip.y - py * rt))
            p.addLine(to: CGPoint(x: c.x - px * wb, y: c.y - py * wb))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: tip.x - rt, y: tip.y - rt, width: rt * 2, height: rt * 2))
        }
        return p
    }
}

// MARK: - OpenAI / Codex (o "nó" da OpenAI)
//
// O the reference notch app desenha o contorno da marca oficial (stroke fino, sem fill).
// O traçado abaixo é a marca oficial normalizada para 0…1 e é traçado com
// 0,80 pt numa caixa de 17 pt (a tinta ocupa 15,75 pt).

struct OpenAIGlyph: Shape {

    static let data: String =
    "M0.9284 0.4092 C0.951 0.3411 0.9432 0.2665 0.9069 0.2046 C0.8524 0.1096 0.7428 0.0608 0.6357 0.0837 " +
    "C0.5753 0.0166 0.4838 -0.0132 0.3955 0.0054 C0.3072 0.0241 0.2355 0.0884 0.2075 0.1742 C0.1372 " +
    "0.1886 0.0765 0.2327 0.0409 0.2951 C-0.0142 0.3899 -0.0017 0.5094 0.0719 0.5908 C0.0492 0.6588 " +
    "0.0569 0.7334 0.0932 0.7954 C0.1478 0.8904 0.2575 0.9392 0.3646 0.9162 C0.4123 0.9699 0.4807 1.0004 " +
    "0.5525 1 C0.6622 1.0001 0.7595 0.9293 0.793 0.8248 C0.8633 0.8103 0.924 0.7663 0.9596 0.7039 C1.014 " +
    "0.6093 1.0015 0.4904 0.9284 0.4092 Z M0.5525 0.9345 C0.5087 0.9346 0.4663 0.9193 0.4326 0.8912 " +
    "L0.4386 0.8878 L0.6377 0.7729 C0.6477 0.767 0.654 0.7562 0.654 0.7445 L0.654 0.4638 L0.7382 0.5125 " +
    "C0.739 0.5129 0.7396 0.5137 0.7398 0.5147 L0.7398 0.7473 C0.7395 0.8506 0.6558 0.9343 0.5525 0.9345 " +
    "Z M0.15 0.7627 C0.128 0.7247 0.1201 0.6803 0.1277 0.6371 L0.1336 0.6406 L0.3329 0.7556 C0.3429 " +
    "0.7614 0.3554 0.7614 0.3654 0.7556 L0.6089 0.6152 L0.6089 0.7124 C0.6088 0.7134 0.6083 0.7144 0.6075 " +
    "0.7149 L0.4058 0.8313 C0.3162 0.8829 0.2017 0.8522 0.15 0.7627 Z M0.0975 0.329 C0.1196 0.2908 0.1546 " +
    "0.2617 0.1961 0.2468 L0.1961 0.4833 C0.1959 0.495 0.2021 0.5058 0.2123 0.5115 L0.4545 0.6513 L0.3703 " +
    "0.7 C0.3694 0.7005 0.3683 0.7005 0.3674 0.7 L0.1661 0.5839 C0.0767 0.532 0.046 0.4176 0.0975 0.328 Z " +
    "M0.789 0.4896 L0.546 0.3485 L0.63 0.3 C0.6309 0.2995 0.632 0.2995 0.6329 0.3 L0.8342 0.4163 C0.897 " +
    "0.4525 0.9333 0.5218 0.9272 0.5941 C0.9212 0.6664 0.874 0.7286 0.806 0.754 L0.806 0.5174 C0.8056 " +
    "0.5058 0.7992 0.4953 0.789 0.4896 Z M0.8728 0.3637 L0.8669 0.3601 L0.668 0.2442 C0.6579 0.2383 " +
    "0.6454 0.2383 0.6353 0.2442 L0.392 0.3846 L0.392 0.2874 C0.3919 0.2864 0.3924 0.2854 0.3932 0.2848 " +
    "L0.5945 0.1687 C0.6575 0.1324 0.7357 0.1358 0.7953 0.1774 C0.8549 0.219 0.8851 0.2913 0.8728 0.3629 " +
    "Z M0.3461 0.5359 L0.2619 0.4875 C0.2611 0.4869 0.2605 0.4861 0.2603 0.4851 L0.2603 0.2531 C0.2604 " +
    "0.1804 0.3025 0.1144 0.3683 0.0835 C0.4341 0.0527 0.5118 0.0627 0.5677 0.1092 L0.5618 0.1125 L0.3627 " +
    "0.2274 C0.3526 0.2334 0.3464 0.2441 0.3463 0.2558 Z M0.3918 0.4374 L0.5003 0.3749 L0.6089 0.4374 " +
    "L0.6089 0.5624 L0.5006 0.6249 L0.392 0.5624 Z"

    /// Traçado unitário, montado uma única vez.
    static let unitPath: Path = {
        var p = Path()
        var nums: [CGFloat] = []
        var op: Character = "M"
        var start = CGPoint.zero
        func flush() {
            switch op {
            case "M": if nums.count >= 2 { start = CGPoint(x: nums[0], y: nums[1]); p.move(to: start) }
            case "L": if nums.count >= 2 { p.addLine(to: CGPoint(x: nums[0], y: nums[1])) }
            case "C": if nums.count >= 6 {
                p.addCurve(to: CGPoint(x: nums[4], y: nums[5]),
                           control1: CGPoint(x: nums[0], y: nums[1]),
                           control2: CGPoint(x: nums[2], y: nums[3]))
            }
            case "Z": p.closeSubpath()
            default: break
            }
            nums.removeAll(keepingCapacity: true)
        }
        var token = ""
        func pushToken() {
            if !token.isEmpty, let v = Double(token) { nums.append(CGFloat(v)) }
            token = ""
        }
        for ch in data {
            if ch == "M" || ch == "L" || ch == "C" || ch == "Z" {
                pushToken(); flush(); op = ch
                if ch == "Z" { flush() }
            } else if ch == " " {
                pushToken()
                if (op == "M" || op == "L") && nums.count == 2 { flush() }
                if op == "C" && nums.count == 6 { flush() }
            } else {
                token.append(ch)
            }
        }
        pushToken(); flush()
        return p
    }()

    func path(in rect: CGRect) -> Path {
        // a tinta ocupa 15,75 de 17 pt (medido: 31,5 px @2x)
        let side = min(rect.width, rect.height) * (15.75 / 17.0)
        let t = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
        return Self.unitPath.applying(CGAffineTransform(scaleX: side, y: side).concatenating(t))
    }
}

// MARK: - Cursor (o cubo)
//
// Hexágono ponta-em-cima 15 × 17 pt com o recorte escuro medido no original:
// metade inferior da face de topo + o triângulo direito. Preenchido com
// even-odd, então basta somar o hexágono e o polígono do buraco.

struct CursorGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func P(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + u * w, y: rect.minY + v * h)
        }
        let top   = P(0.5, 0.0)
        let ur    = P(1.0, 0.2687)
        let lr    = P(1.0, 0.7612)
        let bot   = P(0.5, 1.0)
        let ll    = P(0.0, 0.7612)
        let ul    = P(0.0, 0.2687)
        let mid   = P(0.5, 0.5075)          // encontro das três faces

        var p = Path()
        p.move(to: top); p.addLine(to: ur); p.addLine(to: lr)
        p.addLine(to: bot); p.addLine(to: ll); p.addLine(to: ul)
        p.closeSubpath()

        p.move(to: ul); p.addLine(to: ur); p.addLine(to: bot); p.addLine(to: mid)
        p.closeSubpath()
        return p
    }
}

// MARK: - Antigravity (o arco)
//
// Curva ajustada por mínimos quadrados contra o original (erro médio 7,8/255).
// Caixa natural 17 × 15,5 pt; encaixa centrada nos 17 pt do slot.

struct AntigravityGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let w = s                        // 17 pt
        let h = s * (15.5 / 17.0)        // 15,5 pt
        let ox = rect.midX - w / 2
        let oy = rect.midY - h / 2
        func P(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: ox + u * w, y: oy + v * h) }

        var p = Path()
        p.move(to: P(0.0, 1.0))                                     // pé esquerdo
        p.addCurve(to: P(0.5, 0.0),                                 // ápice
                   control1: P(0.2306, 0.6577), control2: P(0.2868, -0.0329))
        p.addCurve(to: P(1.0, 1.0),                                 // pé direito
                   control1: P(0.7132, -0.0329), control2: P(0.7694, 0.6577))
        p.addLine(to: P(0.9107, 1.0))
        p.addCurve(to: P(0.5, 0.5250),                              // vértice interno
                   control1: P(0.6565, 0.7161), control2: P(0.7127, 0.6249))
        p.addCurve(to: P(0.0893, 1.0),
                   control1: P(0.2873, 0.6249), control2: P(0.3435, 0.7161))
        p.closeSubpath()
        return p
    }
}

// MARK: - Flow (proposto — não existe no app de referência)
//
// Faísca de 4 pontas com lados côncavos: o motivo que o Google usa para os
// produtos generativos (Labs / Flow / Gemini). Só arcos, mesmo peso de tinta
// dos outros quatro. Caixa 17 × 17 pt.

struct FlowGlyph: Shape {
    /// Distância do centro do arco côncavo, em múltiplos de R. 1,0 = faísca
    /// clássica bem afilada; 0,9 dá o mesmo peso visual dos outros glifos.
    var pinch: CGFloat = 0.9

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let k = pinch * R
        let rho = sqrt(k * k + (R - k) * (R - k))
        let tips = [CGPoint(x: 0, y: -R), CGPoint(x: R, y: 0),
                    CGPoint(x: 0, y: R), CGPoint(x: -R, y: 0)]
        let centers = [CGPoint(x: k, y: -k), CGPoint(x: k, y: k),
                       CGPoint(x: -k, y: k), CGPoint(x: -k, y: -k)]
        var p = Path()
        p.move(to: CGPoint(x: c.x + tips[0].x, y: c.y + tips[0].y))
        for i in 0..<4 {
            let ctr = CGPoint(x: c.x + centers[i].x, y: c.y + centers[i].y)
            let a0 = atan2(c.y + tips[i].y - ctr.y, c.x + tips[i].x - ctr.x)
            let a1 = atan2(c.y + tips[(i + 1) % 4].y - ctr.y, c.x + tips[(i + 1) % 4].x - ctr.x)
            p.addArc(center: ctr, radius: rho,
                     startAngle: .radians(a0), endAngle: .radians(a1), clockwise: true)
        }
        p.closeSubpath()
        return p
    }
}


// MARK: - Grok Bot (mascote fantasma)
//
// Não é a marca da x.ai — é o ícone do app "Grok Bot" que o usuário tem instalado
// (extraído do bundle: uma bola/cabeça redonda com dois olhos ovais inclinados,
// tipo fantasma). Desenhado como bola cheia + dois olhos recortados (even-odd fill,
// mesma técnica do CursorGlyph) para ler bem em branco sobre a notch preta.
struct GrokGlyph: Shape {
    private func eye(in box: CGRect, cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, angleDeg: CGFloat) -> Path {
        let side = min(box.width, box.height)
        let ew = side * w, eh = side * h
        var ep = Path(ellipseIn: CGRect(x: -ew/2, y: -eh/2, width: ew, height: eh))
        let center = CGPoint(x: box.minX + side * cx, y: box.minY + side * cy)
        let t = CGAffineTransform(rotationAngle: angleDeg * .pi / 180)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        ep = ep.applying(t)
        return ep
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        let r = side * 0.47
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        p.addPath(eye(in: rect, cx: 0.40, cy: 0.53, w: 0.135, h: 0.34, angleDeg: -20))
        p.addPath(eye(in: rect, cx: 0.615, cy: 0.465, w: 0.135, h: 0.34, angleDeg: -20))
        return p
    }
}
