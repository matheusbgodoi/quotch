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
| Grokbot | grok-4 + grok-3 (diário) | cookies `sso`/`sso-rw` → `POST grok.com/rest/rate-limits` |
| Antigravity | cota diária | ponte local no app em execução (csrf + porta via lsof) |
| Flow | créditos | cookies do Safari (`labs.google`) → sessão → `aisandbox-pa.googleapis.com/v1/credits` |

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
- [x] Grokbot: provedor novo, logo próprio, registrável pelo seletor; lê grok-4/grok-3 por dia.
- [x] Codex 23% (CLI). 
- [x] Parser do `Cookies.binarycookies` do Safari reescrito, com verificação de limites (não crasha mais).
- [x] Cotas honestas: sem número falso; "—" até ler de verdade.

## Pendente / notas
- [ ] Antigravity: a ponte local responde 200 só com o app Antigravity aberto; fechado, cai p/ nuvem (401) e fica stale.
- [ ] Flow: `aisandbox-pa.googleapis.com/v1/credits` passou a devolver 401 mesmo com token de sessão válido (mudança do Google, set/2026). A sessão do Safari ainda dá `access_token`; falta o endpoint novo de créditos. Anel mostra o último valor.
- [ ] Identidade (nome/e-mail) do Grokbot e do Cursor via Safari é opcional; hoje mostra o nome do provedor.
- [ ] Onboarding de 1ª vez explicando o passo único do Full Disk Access.
- [ ] Distribuição: build assinado com Evie Dev não é notarizado; em outra máquina, abrir com clique-direito › Abrir.
