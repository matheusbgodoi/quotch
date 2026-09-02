# Quotch — estado

## Arquitetura de conexão (refeita do zero)
Contas de navegador conectam por **LOGIN DENTRO DO APP** (WKWebView, sessão isolada por conta) — não lê
o Chrome/Safari de fora, não precisa de Full Disk Access, não usa Keychain de terceiro. Leitura por
fetch same-origin na própria página. É o modelo whitelabel: qualquer um clica "Sign in", loga, pronto.

## Por provedor (no "+")
- Claude: "Sign in with Claude…" (login no app) · ou "From the signed-in Claude Code" (Keychain).
- Cursor: "Sign in with Cursor…" · ou "From the Cursor app" (state.vscdb, já lê).
- Flow:   "Sign in with Flow…" (login no app).
- Codex:  "Codex (from the CLI)" — o site do ChatGPT não expõe cota; só o CLI tem.
- Antigravity: "Antigravity (from the app)" (token do Keychain do app dele).

## Conexão pelo NAVEGADOR do usuário (automação, como o Codenotch NÃO faz)
- Flow: Safari → sessão (labs.google/fx/api/auth/session) → /v1/credits com Referer. ✅ 1050/1050.
- Cursor: Safari → cursor.com/api/usage-summary (aba com nonce). ✅
- Claude por PERFIL do Chrome: abre claude.ai no `--profile-directory` do perfil, acha a aba por nonce,
  roda JS (usage + bootstrap). Requer no Chrome: Visualização › Desenvolvedor › "Permitir o JavaScript
  do Eventos da Apple" (pref `AllowJavascriptAppleEvents`; vale na próxima abertura ou ao clicar).
- Safari requer: Desenvolvedor › "Permitir JavaScript de Eventos da Apple". macOS pede "Automação" na 1ª vez.
- Codex: ChatGPT web NÃO tem cota (3ª verificação: só `is_usage_based_seat_enabled`). Fica no CLI.
- Automação serializada (1 por vez) e no ciclo automático no máximo a cada 15 min por conta.

## Feito
- [x] Cotas honestas: sem número falso; "—" até ler de verdade.
- [x] DOIS anéis: externo = janela curta (sessão/diário), interno = semanal (Claude/Codex).
- [x] WebSession reescrita (login no app) para Claude/Cursor/Flow, sessão persistente por conta.
- [x] Config do usuário: Claude Pedro(web), Claude Letícia(web), Codex Pedro(CLI), Cursor(app), Antigravity(Keychain), Flow(web).

## Pendente
- [ ] Verificar leitura logada de ponta a ponta (precisa do login do usuário no app).
- [ ] Onboarding de 1ª vez explicando o login por conta.
