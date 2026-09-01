import SwiftUI

/// Tabela de movimento do Quotch.
/// Tudo marcado "medido" saiu do binario de referência (ver
/// scratchpad/gap/f5-animacao-inventario.txt). O resto esta marcado "autoral".
enum NQMotion {

    // MARK: tokens medidos (globals __DATA 0x1000b1f20…f48 + call sites inline)

    /// Expandir/colapsar o painel, dobrar depois do hover, commit de snapshot. (0xf20)
    static let expand = Animation.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0)
    /// Mudanca de TAMANHO do conteudo (largura/altura do frame). (0xf28)
    static let resize = Animation.spring(response: 0.50, dampingFraction: 0.86, blendDuration: 0)
    /// Entrada de celula (combinar com `entrance(index:)` para o stagger). (0xf30)
    static let insert = Animation.spring(response: 0.36, dampingFraction: 0.82, blendDuration: 0)
    /// Saida de celula. (0xf38)
    static let remove = Animation.easeIn(duration: 0.20)
    /// Percentual/arco indo do valor velho para o novo. (0xf40)
    static let value = Animation.spring(response: 0.90, dampingFraction: 0.90, blendDuration: 0)
    /// Fade de opacidade (transicao e alpha da janela). (0xf48)
    static let fade = Animation.easeInOut(duration: 0.16)
    /// Troca de `hoveredIndex`. (0x100040ee8)
    static let hoverEnter = Animation.spring(response: 0.18, dampingFraction: 0.85, blendDuration: 0)
    /// Escala da celula sob o cursor. (0x1000490c0)
    static let hoverScale = Animation.spring(response: 0.30, dampingFraction: 0.62, blendDuration: 0)
    /// Commit de dados novos vindos da rede. (0x100017a04)
    static let commit = Animation.spring(response: 0.30, dampingFraction: 0.85, blendDuration: 0)
    /// Revelacao de chrome dentro da celula (engrenagem, rotulo). (0x10004d6d4)
    static let reveal = Animation.spring(response: 0.36, dampingFraction: 0.70, blendDuration: 0)
    /// Giro de 360 graus quando um refresh conclui. (0x100049ef8)
    static let refreshSpin = Animation.timingCurve(0.32, 0.0, 0.14, 1.0, duration: 0.95)

    // MARK: constantes medidas

    /// Escala da celula em hover. O the reference notch app ENCOLHE; nao cresce.
    static let hoverScaleFactor: CGFloat = 0.93
    /// Periodo do spinner continuo do TimelineView. (0x10005e2f8)
    static let spinPeriod: TimeInterval = 1.4
    /// Atraso entre por a janela na tela e disparar a spring. (0x1000420b0)
    static let settleDelay: TimeInterval = 0.05
    /// Stagger por indice na entrada. (0x100037ff4)
    static let stagger: TimeInterval = 0.045
    /// Teto do stagger. (0x10003800c)
    static let staggerCap: TimeInterval = 0.18
    /// Duracao do fade de alpha da NSPanel. (0x100041d7c)
    static let windowFade: TimeInterval = 0.16

    // MARK: autorais (o binario nao tem curva propria para estes casos)

    /// Reordenacao por arrasto no Settings — reusa a spring de expansao.
    static let reorder = expand
    /// Girar a pilha de contas: response 0,35 / damping 0,8 (Apple: sheet/flick).
    static let flip = Animation.spring(response: 0.35, dampingFraction: 0.8, blendDuration: 0)
    /// Entrada/saida do estado stale (esmaecimento).
    static let stale = Animation.easeInOut(duration: 0.30)

    /// Entrada escalonada: `.spring(0.36, 0.82).delay(min(i * 0.045, 0.18))`
    static func entrance(index: Int) -> Animation {
        insert.delay(min(Double(index) * stagger, staggerCap))
    }

    /// Portao unico de Reduce Motion. Todo `.animation(...)` do app passa por aqui.
    @inline(__always)
    static func gated(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}