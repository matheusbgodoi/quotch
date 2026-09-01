# Design tokens — medidos, não inferidos

Fonte: `panel.png` (@2x, painel isolado com alfa) + disassembly ARM64.
Onde este arquivo diverge de `spec.md`, **este vale** — o spec §4 foi escrito sem a frente visual,
que falhou por timeout.

## Correções ao spec

| Item | spec.md dizia | **medido** |
|---|---|---|
| Verde de progresso | `#00FF88` | **`#75FB94`** — 331 px puros no arco do Claude |
| Diâmetro externo do anel | 44,0 pt | **43,0 pt** de cor pura (+ antialiasing ⇒ 44 na caixa) |
| Espessura da trilha | ~5,7 pt | **5,0 pt** puros ⇒ `lineWidth: 6` com AA |

## Confirmados

| Item | Valor | Como foi medido |
|---|---|---|
| Largura do painel | **70,0 pt** | bbox alfa do painel |
| Passo vertical entre células | **102,5 pt** | distância entre centros de anéis consecutivos |
| Espessura do arco de progresso | **3,0 pt** | varredura vertical na coluna central |
| Cor da trilha | **`#303030`** | cor mais frequente do anel |
| Opacidade de célula stale | **0,45** | trilha stale mede `#161616` → 22/48 = 0,458 |
| Cap height do rótulo % | **9,0 pt** | ⇒ `system(size: 13, weight: .semibold)` |
| Topo do rótulo % | **35,8 pt** abaixo do centro do anel | |
| Glifo (cubo Cursor) | **14,5 × 16,0 pt** | bbox de pixels brancos |
| Comprimento da ponta (tail) | **63 pt** do bico até a largura cheia | perfil de largura |
| Raio do canto do corpo | **≈ 24 pt** | ajuste do perfil de largura |

## Camada de janela (do disassembly, não é palpite)

| Item | Valor | Evidência |
|---|---|---|
| `styleMask` | `.nonactivatingPanel` apenas (0x80) — **sem** `.borderless` | |
| `level` | **25** (`.statusBar`) — acima da barra de menus (24) | `mov w2, #0x19` + `setLevel:` |
| `collectionBehavior` | **0x111** = `.canJoinAllSpaces │ .stationary │ .fullScreenAuxiliary` | `mov w2, #0x111` |
| Hover | `NSEvent` global+local monitors, máscara **0x60** (`.mouseMoved │ .leftMouseDragged`) + poll 0,3 s | zero `NSTrackingArea`, zero CGEventTap |
| Click-through | `ignoresMouseEvents = (hitIndex == -1)` contra `interactiveRects` | `CGRectContainsPoint` + `cset w2, eq` |
| Graça para abrir | **0,25 s** | `fmov d0, #0.25` + `asyncAfter` |
| Graça para fechar | **0,45 s** | |
| Fade da janela | **0,16 s** | constante `0x3FC47AE147AE147B` |
| Acessibilidade | **não pede** | zero `AXIsProcessTrusted` |

O array `interactiveRects` já é indexado — a arquitetura de referência **já é "N slots"**.
Multi-conta não exige mudança nenhuma na camada de janela: basta cada slot carregar
`(providerID, accountID, glyph)` e a ordem vir das preferências.
