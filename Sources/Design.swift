import SwiftUI

/// Tokens de referência. Valores da tabela de conflitos do docs/backlog.md —
/// literal do binário > ajuste numérico > medida de pixel > inferência.
///
/// ATENÇÃO sobre cor: `panel.png` está em Display P3. Cor SÓ se mede em
/// `panel_srgb.png`. Foi essa armadilha que produziu o #75FB94 errado.
enum NQ {
    // MARK: Geometria da faixa
    static let stripThickness: CGFloat = 69.948718     // espessura do desenho preto
    static let windowThickness: CGFloat = 335          // janela: folga transversal p/ o cartão de hover
    static let panelWidth: CGFloat = stripThickness    // compat
    static let endMargin: CGFloat = 71.452991          // folga em CADA ponta do eixo longo
    static let cellBlock: CGFloat = 71.116239          // bloco de uma célula
    static let cellGap: CGFloat = 31.401709            // espaço entre células
    static let verticalStep: CGFloat = 102.517949      // cellBlock + cellGap
    static let cellTopPadding: CGFloat = endMargin
    static let cellBottomPadding: CGFloat = endMargin

    // MARK: Anel
    static let ringOuterDiameter: CGFloat = 44
    static let trackLineWidth: CGFloat = 6
    static let arcLineWidth: CGFloat = 3
    static var ringRadius: CGFloat { (ringOuterDiameter - trackLineWidth) / 2 }   // 19
    static let glyphSize: CGFloat = 17

    // MARK: Silhueta
    static let curlRadius: CGFloat = 46                // filete côncavo (38,7 no binário; ajustado ao perfil medido)
    static let cornerRadius: CGFloat = 23              // canto convexo (29,6 no binário; idem)
    static let pillThickness: CGFloat = 10
    static let pillLength: CGFloat = 78

    // MARK: Cores (sRGB explícito — ver nota acima)
    static let track      = Color(.sRGB, red: 0.1882353, green: 0.1882353, blue: 0.1882353, opacity: 1) // #303030
    static let ample      = Color(.sRGB, red: 0,         green: 1.0,       blue: 0.5333333, opacity: 1) // #00FF88
    static let watch      = Color(.sRGB, red: 0.9490196, green: 1.0,       blue: 0,         opacity: 1) // #F2FF00
    static let critical   = Color(.sRGB, red: 1.0,       green: 0.2470588, blue: 0,         opacity: 1) // #FF3F00
    static let exhausted  = Color(.sRGB, red: 1.0,       green: 0.2470588, blue: 0,         opacity: 1) // [A MEDIR]
    static let body       = Color.black
    static let onSurface  = Color.white
    static let secondary  = Color(.sRGB, white: 0.5019608, opacity: 1)  // #808080
    static let staleOpacity: Double = 0.45

    // MARK: Cartão de hover (medido: 226 pt à esquerda da faixa, bico apontando o anel)
    static let hoverCardWidth: CGFloat = 226
    static let hoverCardPointer: CGFloat = 9
    static let barTrack   = Color(.sRGB, white: 0.1764706, opacity: 1)  // #2D2D2D
    static let surfaceAlt = Color(.sRGB, white: 0.1764706, opacity: 1)

    // MARK: Tipografia — cap height medida 10,5 pt / 0,70 = 15
    static let percentFont = Font.system(size: 15, weight: .semibold)

    /// Limiares literais do binário (0x100049908–0x100049948): 0,5 / 0,7 / 1,0.
    static func band(_ f: Double) -> Color {
        if f >= 1.0 { return exhausted }
        if f >= 0.7 { return critical }
        if f >= 0.5 { return watch }
        return ample
    }

    /// Comprimento do desenho para n células (forma decomposta — L(4) = 501,87 ✓).
    static func stripLength(_ n: Int) -> CGFloat {
        guard n > 0 else { return pillLength }
        return 2 * endMargin + CGFloat(n) * cellBlock + CGFloat(max(0, n - 1)) * cellGap
    }
}

/// Alias de geometria usado pela SideNotchShape (a frente de colapso batizou assim).
enum NQGeo {
    static let stripThickness = NQ.stripThickness
    static let curlRadius = NQ.curlRadius
    static let cornerRadius = NQ.cornerRadius
    static let pillThickness = NQ.pillThickness
    static let pillLength = NQ.pillLength
    /// A pílula é fina: o filete e o canto encolhem proporcionalmente à espessura.
    static let pillCurlRadius = NQ.curlRadius * (NQ.pillThickness / NQ.stripThickness)
    static let pillCornerRadius = NQ.pillThickness / 2
}

/// Tempos de hover — conflito C9 do backlog: expandir é IMEDIATO; o que tem graça
/// é colapsar (0,45 s) e limpar o `hoveredIndex` ao sair da célula (0,25 s).
/// Troca de célula para célula é imediata.
enum NQTiming {
    static let expandDelay: TimeInterval = 0        // imediato
    static let foldGrace: TimeInterval = 0.45
    static let clearHoverGrace: TimeInterval = 0.25
    static let windowFade: TimeInterval = 0.16
    static let cursorPoll: TimeInterval = 0.3
}
