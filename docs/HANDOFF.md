# Quotch — handoff (leia isto primeiro se você é outra IA/pessoa continuando)

**O que é:** app macOS que mostra na notch/borda da tela a cota de uso de várias IAs, com **várias contas por provedor**
(cartas empilhadas), visual 1:1 com o app "the reference notch app" e melhorias. Exclusivo macOS 14+, Swift/AppKit+SwiftUI, sem Xcode.

## Como rodar
    bash build.sh            # compila com swiftc e instala /Applications/Quotch.app (assinatura ad-hoc)
    open -g -a Quotch        # roda fora da Dock; passe o mouse na borda direita
    pkill -f Quotch          # fecha
Preferências: `defaults read com.matheus.quotch` (JSON em `config`). `defaults delete com.matheus.quotch` reseta.

## Testar SEM mexer no mouse do usuário (canal de teste)
    touch /tmp/qt-hitlog                  # liga o modo dev (log em /tmp/qt-hit.log)
    echo "expand" > /tmp/qt-cmd           # expand | collapse | hover N | unhover | hoverbody 1/0 | flip N | settings | settings-close | dump | release
Capturas: `screencapture -x -o -l <windowID>`; o id vem de `/tmp/wid` (fonte em /tmp/wid.swift — recrie se sumir:
lista janelas do owner "Quotch" com layer 25 via CGWindowListCopyWindowInfo).

## Mapa do código (Sources/)
- `Design.swift` tokens medidos de referência (docs/design-tokens.md SOBREPÕE docs/spec.md §4). Cor só se mede em sRGB.
- `NotchShape.swift` silhueta (2 arcos por ponta, amostrados). `NotchGeometry.swift` motor de layout (janela 335 pt, escada de densidade, gearRow).
- `NotchPanel.swift` NSPanel (styleMask .nonactivatingPanel, level 25, behavior 0x111), hit-test por rects, hover, scroll, clique, menu, canal de teste.
- `NotchView.swift` raiz: morph pílula↔faixa, stagger, cartão de hover, engrenagem redonda que emerge no hover. `Stacks.swift` pilha de contas.
- `Glyphs.swift` marcas medidas. `Motion.swift` springs do binário. `Spinner.swift` arco de atividade + giro de refresh.
- `Identity.swift` e-mail/nome/plano sem tocar em token. `Providers.swift` leituras reais + `RefreshCoordinator`.
- `Config.swift` modelo persistido (AppConfig/AccountConfig, decoder tolerante — **todo campo novo precisa entrar no init(from:)**), `ConfigBridge.swift` config→model, `Settings*.swift` janela.

## Decisões que não estão no código
- Clique numa célula = atualizar a cota; abrir o site só pelo menu de botão direito (pedido do usuário).
- Engrenagem: escondida atrás da ponta; no hover a faixa cresce 58 pt e o botão redondo aparece (spring reveal 0,36/0,70).
- Claude via Keychain é opt-in (toggle) porque o macOS abre diálogo.
- Grokbot lê o limite semanal do app Grok Bot via Electron safeStorage; o macOS pede acesso ao item
  `Grok Bot Safe Storage` uma vez. Não usar as cotas diárias do chat em `grok.com`.
- Flow usa uma WKWebView isolada e calcula uso mensal com `subscriptionCredits` + tier do plano;
  `credits` sozinho é saldo e nunca deve ser usado como o próprio denominador.
- 1ª conta de cada provedor = "viva" (credencial da ferramenta dona); as demais ainda são demonstração até existir o cofre (ver TASKS).

## Cofre (multi-conta real)
- `Vault.swift`: `~/Library/Application Support/Quotch/vault.json` (0600), `[UUID: VaultedCredential]`.
- Regra: a **1ª conta de cada provedor sem cofre é a "viva"** (espelha a ferramenta dona). Toda conta capturada
  pelo "+" do Settings lê com a credencial da captura (Cursor cookie; Claude accessToken até expirar — não renovamos,
  refresh token pode rotacionar e deslogar o Claude Code; Codex só guarda a última leitura, porque o dado é local da conta ativa).
- Fluxo do usuário: logar no tool com a conta B → Settings → "+" → nome → Capture. Para trocar de volta, logar A de novo.
- Cache: `lastGoodReadings.json` no mesmo diretório, pintado no launch (stale se > 300 s).

## Modo demo (para prints/GIF sem PII)
`touch /tmp/quotch-demo` antes de abrir: contas falsas (personal/work), showEmails off, sem IdentityProbe nem provedores reais.
GIF do README: dirige pelo canal `/tmp/qt-cmd`, captura a janela (transparente) e compõe sobre fundo neutro
(script no histórico: frames em scratchpad/rec → rec2 → ffmpeg). Sempre remover `/tmp/quotch-demo` e relançar para voltar ao normal.

## Bordas
`NotchEdge` muda: posição da janela (NotchGeometry), `AxisStack` (VStack/HStack), gatilho e pílula (`edgeTriggerScreen`/`pillRectWindow`), bico do cartão (`CardWithBeak.beakEdge`). Teste com `echo "edge top" > /tmp/qt-cmd`.

## Cookies do Chrome — o que dá e o que NÃO dá (investigado, docs/browser-cookies-investigacao.md)
`ChromeCookies.swift` descriptografa cookies v10 por perfil (Safe Storage/Keychain). ENTREGA identidade + plano
(Claude `/api/bootstrap`=200, ChatGPT `/api/auth/session`=200). NÃO entrega % de uso: Claude `/usage`=403 (endpoint
de organização, não da conta consumer), ChatGPT não tem endpoint de cota. Logo o navegador não substitui a leitura
de uso da ferramenta de desktop. Cloudflare barra curl (fingerprint TLS); URLSession precisa User-Agent de navegador.

## Adicionar / trocar conta (como o usuário pensa)
"+" no Settings mostra **quem está logado agora** na ferramenta dona (IdentityProbe a cada 2 s). Se não é a conta desejada,
"Switch…" abre a página de conta pelo seletor de navegador (`abrir://`) e o usuário troca o login NA FERRAMENTA
(claude /login, codex login, sign out no Cursor…). Capture então guarda credencial + identidade dessa conta no cofre.
Depois do Switch, `NQLink.scheduleReconcile()` re-detecta em 5/20/60 s e dispara refresh; há também um timer de 2 min.

## Armadilhas já pagas
- `panel.png` da dissecação é Display P3: #75FB94 era #00FF88. Medir cor só em `panel_srgb.png`.
- state.vscdb do Cursor é WAL: abrir cópia com SQLITE_OPEN_READWRITE (read-only dá erro 14).
- TCC: o app lançado pelo Finder não lê `Local State` do Chrome; ler pelo build.sh (Terminal).
- NSHostingView engole mouseDown: cliques são interceptados em `sendEvent`.
- Trocar activation policy e ativar no mesmo tick deixa a janela atrás: despachar para o tick seguinte.
