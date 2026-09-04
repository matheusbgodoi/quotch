# Quotch — estado

## Arquitetura de conexão (atual)
Contas de navegador são lidas **em segundo plano, sem abrir nada na tela**:
Quotch lê o cookie de sessão que o próprio navegador já guarda, monta o header e chama a
API de uso do provedor por HTTPS (URLSession). Nenhuma aba, nenhuma janela, nenhum AppleScript.

- **Full Disk Access** é obrigatório uma vez: o macOS guarda os cookies de todo navegador numa
  pasta protegida. Concedido uma vez, todas as contas de navegador (todos os provedores e perfis)
  passam a ler silenciosamente. O app detecta FDA por `BrowserAccess.hasFullDiskAccess()` e, sem ele,
  mostra um aviso no seletor de contas com botão que abre o painel.
- **Assinatura estável**: `build.sh` assina com a identidade `Evie Dev` (ou `$QUOTCH_SIGN_ID`).
  O TCC ancora o FDA na identidade, não no cdhash, então a concessão sobrevive a rebuilds/updates.
  Sem identidade, cai para ad-hoc (aí o FDA não persiste entre builds).
- `build-dmg.sh` empacota o app já instalado (não recompila, pra não trocar assinatura).

## Fontes por provedor
| Provedor | Anéis | Fonte |
|---|---|---|
| Claude | sessão + semanal | cookie `sessionKey` do Chrome (por perfil) ou Safari → `claude.ai/api/…/usage`; ou Keychain do Claude Code |
| Codex | limite semanal | arquivos locais do CLI (`~/.codex`) — sem rede |
| Cursor | Cursor Models + Other Models | cookie `WorkosCursorSessionToken` → `cursor.com/api/usage-summary` (`autoPercentUsed`/`apiPercentUsed`) |
| Grokbot | limite semanal | login do app Grok Bot (Electron safeStorage) → `DashboardService/GetSandUsageStatus` |
| Antigravity | cota diária | ponte local no app em execução (csrf + porta via lsof) |
| Flow | créditos mensais usados | WKWebView isolada captura o saldo; plano define o total mensal (200/1.000/10.000/25.000) |

## Interação
- Trocar de conta numa pilha: **scroll**. Usa o eixo dominante — vertical (wheel comum / 2 dedos)
  ou **horizontal** (thumbwheel lateral do MX Master, swipe lateral no trackpad). Direita/baixo = próxima.
- Sensibilidade: acumula o gesto; troca só a cada ~140 pt percorridos e no máximo 1 a cada 0,5 s
  (`handleScroll` em `NotchPanel.swift`) — evita troca acidental com o thumbwheel.

## Feito (verificado no app, com FDA ligado)
- [x] FDA funcionando e persistente entre rebuilds (assinatura Evie Dev). `hasFDA()=true`, tudo READ-OK.
- [x] Leitura em segundo plano, SEM abrir aba/janela (confirmado: nenhum `osascript`).
- [x] Claude Pedro (Chrome Profile 1) e Letícia (Chrome Profile 2) — sessão + semanal, com nome/e-mail.
- [x] Cursor com DOIS anéis: Cursor Models (auto) + Other Models (api).
- [x] Grokbot: logo próprio (o mascote fantasma do app instalado, não a marca da x.ai) e leitura
      do único limite semanal exposto pelo Grok Bot, usando a sessão que o próprio app mantém.
- [x] Claude: `weekly_scoped` identificado como Fable; Opus só é mostrado quando o payload declara Opus.
- [x] Flow: captura `subscriptionCredits`, plano e top-ups da sessão web; calcula o anel contra a franquia
      mensal oficial do plano em vez de tratar o saldo atual como denominador.
- [x] Codex 23% (CLI). 
- [x] Parser do `Cookies.binarycookies` do Safari reescrito, com verificação de limites (não crasha mais).
- [x] Cotas honestas: sem número falso; "—" até ler de verdade.
- [x] Corrida de layout no launch (`main.swift`): a primeira `apply()` do bridge rodava antes de
      `onSlotCountChange` ser ligado, então a janela ficava do tamanho do modelo de demonstração
      (5 provedores) até outro evento reajustar. Invisível enquanto o usuário tinha exatamente 5
      provedores (igual ao mock); com o 6º (Grokbot), o último da lista ficava fora da silhueta —
      presente na config e lido normalmente, só não desenhado. Corrigido com um `scheduleRelayout()`
      explícito após ligar os closures.
- [x] Instalação do zero documentada no README: o release não é notarizado pela Apple, então precisa
      de clique-direito → Abrir na primeira vez (Gatekeeper); e o segundo prompt do macOS — Keychain
      "Chrome Safe Storage", separado do Full Disk Access — também está explicado.

## Pendente / notas
- [ ] Antigravity: a ponte local responde 200 só com o app Antigravity aberto; fechado, cai p/ nuvem (401) e fica stale.
- [ ] Identidade (nome/e-mail) do Grokbot é opcional; hoje mostra o nome do provedor.
- [ ] Distribuição: build assinado com Evie Dev não é notarizado; em outra máquina, abrir com clique-direito › Abrir (documentado no README).
