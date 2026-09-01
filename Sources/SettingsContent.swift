import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Medidas e textos da janela
// Tom de voz herdado de referência (docs/dissecacao/assets-e-icones.md, secção "TOM DE VOZ"):
// inglês britânico, sentence case sempre, frases curtas e declarativas, travessão U+2014
// espaçado como conector, interponto U+00B7 como separador, reticências U+2026 em ações que
// abrem outra coisa, e TODO controlo com uma linha de help que descreve a CONSEQUÊNCIA.

enum NQSettings {
    static let title = "Quotch Settings"
    static let width: CGFloat = 560      // o original mede 500 × 560; ampliado para caber a árvore de contas
    static let height: CGFloat = 620
    static let authorName = "matheusbgodoi"
    static let authorLink: String? = "https://www.linkedin.com/in/matheusgodoi-engbio/"

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1"
    }

    static let emptyTitle = "Connect an assistant to get started"
    static let emptyBody = "Quotch reads usage from tools already signed in on this Mac — it never asks for your password. Install and sign in to any of Claude Code (the terminal tool, not the Claude app), Cursor, Codex or Antigravity, and its ring appears in the notch."
    static let emptyNote = "macOS will ask once for permission to read Claude Code's and Antigravity's saved logins. Choose Always Allow — plain Allow makes it ask again every time."

    static let reorderHelp = "Drag a ring to reorder it; the notch follows."
    static let addHelp = "Reads a login that is already on this Mac."
    static let removeHelp = "Stops reading it and forgets its readings. You stay signed in to the tool that owns it."

    static let credentialsFooter = "Quotch never signs in for you — each reading is borrowed from the tool that already holds the account. Signing out here stops the credential being read and forgets the numbers, but leaves you signed in to that tool. macOS asks once per tool the first time, and again whenever you sign in to a different account; Always Allow keeps it quiet."

    static func signedOutState() -> String { "Signed out — nothing is read, and no readings are kept." }
    static func switchOffHelp(_ name: String) -> String {
        "Switch off to stop reading \(name) and forget its readings. You stay signed in to the tool that owns the account."
    }
    static func switchOnHelp(_ name: String) -> String { "Switch on to read \(name) again." }
    static func hiddenHelp(_ name: String) -> String {
        "Hidden from the notch. \(name) is still read, so the ring is up to date the moment you show it again."
    }
    static func openHelp(_ site: String) -> String {
        "Opens \(site) in your browser. That site has its own sign-in, separate from the credential read here."
    }
    static func captureHelp(_ tool: String) -> String {
        "Sign in to \(tool) with the account you want, then click Capture. Quotch keeps its own copy of that login, so the ring keeps reading after you switch back."
    }
}

// MARK: - Glifo em superfície clara
// Os glifos são brancos (desenhados para o corpo preto da notch). Na janela de Settings
// eles vão numa pastilha preta com o mesmo raio do corpo — a linha lê como um pedaço da notch.

struct AccountGlyphChip: View {
    var glyph: GlyphID
    var size: CGFloat = 24
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(NQ.body)
            if let kind = glyph.drawableKind {
                Glyph(kind: kind, size: size * 0.58)
            } else {
                Circle()
                    .stroke(NQ.onSurface, lineWidth: max(1.5, size * 0.09))
                    .frame(width: size * 0.5, height: size * 0.5)
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? NQ.staleOpacity : 1)
    }
}

// MARK: - Raiz

struct SettingsRootView: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            IntegrationsSection(store: store)
            NotchSection(store: store)
            StartupSection()
            UpdatesSection()
            CredentialsFooter()
        }
        .formStyle(.grouped)
        .frame(width: NQSettings.width, height: NQSettings.height)
    }
}

// MARK: - Secção 1 — Integrations

struct CaptureRequest: Identifiable { let id = UUID(); let kind: ProviderKind }

struct IntegrationsSection: View {
    @ObservedObject var store: ConfigStore
    @State private var expanded: Set<ProviderKind> = []
    @State private var selection: UUID?
    @State private var capture: CaptureRequest?
    @State private var browserPick: CaptureRequest?
    @State private var removal: AccountConfig?

    private var kinds: [ProviderKind] { store.config.orderedKinds }
    private var groupedKinds: [(ProviderCategory, [ProviderKind])] {
        guard store.config.groupByCategory else { return [(.coding, kinds)] }
        let coding = kinds.filter { $0.category == .coding }
        let gen = kinds.filter { $0.category == .generation }
        return [(.coding, coding), (.generation, gen)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        Section {
            if store.config.accounts.isEmpty {
                EmptyIntegrations()
            } else {
                ForEach(groupedKinds, id: \.0) { category, list in
                    if store.config.groupByCategory && groupedKinds.count > 1 {
                        Text(category.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    ForEach(list, id: \.self) { kind in
                        ProviderGroup(store: store,
                                      kind: kind,
                                      expanded: $expanded,
                                      selection: $selection,
                                      removal: $removal)
                    }
                }
            }
            AddRemoveBar(store: store, selection: $selection, capture: $capture, browserPick: $browserPick, removal: $removal)
        } header: {
            Text("Integrations")
        } footer: {
            if !store.config.accounts.isEmpty {
                Text(NQSettings.reorderHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Show e-mail addresses", isOn: Binding(
                    get: { store.config.showEmails },
                    set: { store.config.showEmails = $0 }))
                Text("Off shows the person's name instead — in the notch card and in this list.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow Keychain access (Claude Code, Antigravity)", isOn: Binding(
                    get: { store.config.readClaudeKeychain },
                    set: { store.config.readClaudeKeychain = $0 }))
                Text("Only these two tools keep their login in the macOS Keychain, so macOS asks once — choose Always Allow. Codex and Cursor keep theirs in files and need no permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $browserPick) { req in
            BrowserPickerSheet(kind: req.kind) { source in
                let id = store.addAccount(kind: req.kind, chromeProfile: source)
                expanded.insert(req.kind)
                Task { @MainActor in
                    if let src = BrowserSource.parse(source), let ident = await Providers.browserIdentity(kind: req.kind, source: src) {
                        store.setIdentity(id, ident)
                    }
                    NotificationCenter.default.post(name: .quotchRefresh, object: nil)
                }
            }
        }
        .sheet(item: $capture) { req in
            CaptureSheet(kind: req.kind) { nickname in
                let id = store.addAccount(kind: req.kind, nickname: nickname)
                _ = Vault.capture(kind: req.kind, for: id, allowKeychain: store.config.readClaudeKeychain)
                NotificationCenter.default.post(name: .quotchRefresh, object: nil)
                expanded.insert(req.kind)
            }
        }
        .alert("Remove \(removal?.title ?? "")?",
               isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Remove", role: .destructive) {
                if let r = removal { store.removeAccount(r.id); if selection == r.id { selection = nil } }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text(NQSettings.removeHelp)
        }
    }
}

struct EmptyIntegrations: View {
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(NQSettings.emptyTitle)
                .font(.headline)
            Text(NQSettings.emptyBody)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(NQSettings.emptyNote)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

/// Uma linha por provedor; as contas são as sub-linhas. Zero secções novas — é a
/// secção "Integrations" do original com um nível a mais.
struct ProviderGroup: View {
    @ObservedObject var store: ConfigStore
    let kind: ProviderKind
    @Binding var expanded: Set<ProviderKind>
    @Binding var selection: UUID?
    @Binding var removal: AccountConfig?

    private var accounts: [AccountConfig] { store.config.accounts(of: kind) }
    private var isExpanded: Binding<Bool> {
        Binding(get: { expanded.contains(kind) },
                set: { open in
                    if open { expanded.insert(kind) } else { expanded.remove(kind) }
                })
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(accounts) { account in
                AccountRow(store: store,
                           id: account.id,
                           selection: $selection,
                           removal: $removal)
            }
            .onMove { source, destination in
                store.moveAccounts(in: kind, from: source, to: destination)
            }
        } label: {
            HStack(spacing: 8) {
                AccountGlyphChip(glyph: kind.defaultGlyph, size: 20)
                Text(kind.displayName)
                Text("· \(accounts.count) \(accounts.count == 1 ? "account" : "accounts")")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }
}

struct AccountRow: View {
    @ObservedObject var store: ConfigStore
    let id: UUID
    @Binding var selection: UUID?
    @Binding var removal: AccountConfig?

    @State private var draft = ""
    @State private var editing = false
    @State private var dropTargeted = false
    @State private var hovering = false
    @FocusState private var nameFocused: Bool

    private var account: AccountConfig {
        store.config.accounts.first { $0.id == id } ?? AccountConfig(kind: .claude)
    }
    private var isSelected: Bool { selection == id }

    var body: some View {
        let acc = account
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                glyphMenu(acc)

                // Renomear inline: o campo não tem moldura até receber foco.
                TextField("Name this account", text: $draft)
                    .textFieldStyle(.plain)
                    .labelsHidden()            // sem isto o Form parte a linha em label + valor
                    .focused($nameFocused)
                    .font(.body)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }

                Spacer(minLength: 8)

                Button {
                    store.binding(account: id).wrappedValue.isVisible.toggle()
                } label: {
                    Image(systemName: acc.isVisible ? "eye" : "eye.slash")
                        .foregroundStyle(acc.isVisible ? Color.secondary : Color.secondary.opacity(0.45))
                }
                .buttonStyle(.borderless)
                .help(acc.isVisible ? "Hide this ring in the notch." : NQSettings.hiddenHelp(acc.title))

                Toggle("", isOn: store.binding(account: id).isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            Text(acc.subtitle(showEmail: store.config.showEmails))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if acc.chromeProfile == "web" {
                    // Conta que conecta por login no app: reconectar/entrar.
                    Button(acc.email == nil ? "Sign in…" : "Reconnect…") {
                        WebSession.shared.signIn(accountID: acc.id, kind: acc.kind) { _ in
                            Task { @MainActor in
                                if let id = await WebSession.shared.identity(accountID: acc.id, kind: acc.kind) { store.setIdentity(acc.id, id) }
                                NotificationCenter.default.post(name: .quotchRefresh, object: nil)
                            }
                        }
                    }
                    .buttonStyle(.link)
                }
                Button("Open \(acc.kind.site)") { NQLink.open(acc.kind.managePath) }
                    .buttonStyle(.link)
                    .help(NQSettings.openHelp(acc.kind.site))
            }
            .font(.callout)

            if let line = helpLine(acc) {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
                .overlay(alignment: .top) {
                    if dropTargeted {
                        Rectangle().fill(Color.accentColor).frame(height: 2)
                    }
                }
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { selection = id }
        .opacity(acc.isEnabled ? 1 : 0.55)
        // Reordenação por arrasto. `.onMove` cobre o caso dentro do grupo quando a
        // secção é uma List; aqui, dentro de um Form, quem funciona é drag & drop.
        .draggable(id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UUID(uuidString: raw) else { return false }
            store.drop(dragged, onto: id)
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("Rename") { nameFocused = true }
            Button("Move up") { store.nudge(id, by: -1) }
            Button("Move down") { store.nudge(id, by: 1) }
            Divider()
            Button("Remove \(acc.title)", role: .destructive) { removal = acc }
        }
        .onAppear { draft = acc.nickname }
    }

    @ViewBuilder private func glyphMenu(_ acc: AccountConfig) -> some View {
        Menu {
            Picker("Logo", selection: store.binding(account: id).glyph) {
                ForEach(GlyphID.allCases) { g in Text(g.label).tag(g) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            AccountGlyphChip(glyph: acc.glyph, size: 24, dimmed: !acc.isEnabled)
        }
        .buttonStyle(.plain)               // .menuStyle(.borderlessButton) não desenha o label
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The mark inside this ring in the notch.")
    }

    private func commitName() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != account.nickname else { return }
        store.rename(id, to: trimmed)
    }

    /// Toda opção tem help que descreve a consequência (regra 4 do tom de voz). Estado fora do
    /// normal mostra sempre; estado normal mostra no hover, para 6 contas não virarem 24 linhas.
    private func helpLine(_ acc: AccountConfig) -> String? {
        if !acc.isEnabled { return NQSettings.signedOutState() + " " + NQSettings.switchOnHelp(acc.title) }
        if !acc.isVisible { return NQSettings.hiddenHelp(acc.title) }
        return hovering ? NQSettings.switchOffHelp(acc.title) : nil
    }
}

/// Barra fina no rodapé da secção, no estilo Mail/Contactos.
struct AddRemoveBar: View {
    private func signInWeb(_ kind: ProviderKind) {
        let id = store.addAccount(kind: kind, chromeProfile: "web")
        WebSession.shared.signIn(accountID: id, kind: kind) { _ in
            Task { @MainActor in
                if let ident = await WebSession.shared.identity(accountID: id, kind: kind) { store.setIdentity(id, ident) }
                NotificationCenter.default.post(name: .quotchRefresh, object: nil)
            }
        }
    }
    @ViewBuilder private func addMenuItem(_ kind: ProviderKind) -> some View {
        switch kind {
        case .claude:
            Menu("Claude") {
                Button("Sign in with Claude…") { signInWeb(.claude) }
                Button("From the signed-in Claude Code") { capture = CaptureRequest(kind: .claude) }
            }
        case .cursor:
            Menu("Cursor") {
                Button("Sign in with Cursor…") { signInWeb(.cursor) }
                Button("From the Cursor app") { store.addAccount(kind: .cursor) }
            }
        case .flow:
            Button("Sign in with Flow…") { signInWeb(.flow) }
        case .codex:
            Button("Codex (from the CLI)") { store.addAccount(kind: .codex) }
        case .antigravity:
            Button("Antigravity (from the app)") { store.addAccount(kind: .antigravity) }
        }
    }

    @ObservedObject var store: ConfigStore
    @Binding var selection: UUID?
    @Binding var capture: CaptureRequest?
    @Binding var browserPick: CaptureRequest?
    @Binding var removal: AccountConfig?

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    addMenuItem(kind)
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help(NQSettings.addHelp)

            Button {
                if let id = selection, let a = store.config.accounts.first(where: { $0.id == id }) { removal = a }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(selection == nil)
            .help(NQSettings.removeHelp)

            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

/// Fluxo de captura para os provedores `.snapshotOfActive` (spec §1.3, passo 1).
struct CaptureSheet: View {
    let kind: ProviderKind
    var onCapture: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var detected: AccountIdentity? = nil
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var howToSwitch: String {
        switch kind {
        case .claude:      return "Quotch reads the login of Claude Code (the desktop tool), not the browser. In Terminal, run  claude /login  and pick the account."
        case .codex:       return "Quotch reads the login of the Codex CLI, not chatgpt.com in the browser. In Terminal, run  codex login  with the account you want."
        case .cursor:      return "Quotch reads the login of the Cursor editor, not the browser. In Cursor: Settings → Account → sign out, then sign in again."
        case .antigravity: return "Quotch reads the login of the Antigravity app. Sign out there and sign in with the other Google account."
        case .flow:        return "Flow accounts come from a browser session (planned)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AccountGlyphChip(glyph: kind.defaultGlyph, size: 28)
                Text("Add a \(kind.displayName) account").font(.headline)
            }
            // Quem está logado AGORA na ferramenta — é isto que vai ser capturado.
            HStack(spacing: 8) {
                Image(systemName: detected?.email == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.badge.checkmark")
                    .foregroundStyle(detected?.email == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(detected?.email ?? "No \(kind.toolName) login detected yet")
                        .font(.callout.weight(.medium))
                    Text([detected?.name, detected?.plan].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open \(kind.toolName == "Codex" ? "chatgpt.com" : kind.managePath.split(separator: "/").first.map(String.init) ?? "site")…") { NQLink.open(kind.managePath); NQLink.scheduleReconcile() }
                    .help("Opens the account page in the browser you choose. Switching there does NOT change the desktop tool's login.")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Text("Not the account you want? \(howToSwitch) This list updates by itself.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name this account", text: $nickname)
                .textFieldStyle(.roundedBorder)
            Text("The name is yours — it is what tells two \(kind.displayName) rings apart here.")
                .font(.callout).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Capture") { onCapture(nickname); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(detected?.email == nil && kind != .flow)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { detected = IdentityProbe.probe(kind) }
        .onReceive(tick) { _ in detected = IdentityProbe.probe(kind) }
    }
}

// MARK: - Secção 2 — The notch

struct NotchSection: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Show", selection: store.binding(\.notchVisibility)) {
                    ForEach(NotchVisibility.allCases) { v in Text(v.title).tag(v) }
                }
                Text(store.config.notchVisibility.help)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Edge", selection: store.binding(\.notchEdge)) {
                    ForEach(NotchEdge.allCases) { e in Text(e.title).tag(e) }
                }
                Text(store.config.notchEdge.help)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Group by kind", isOn: store.binding(\.groupByCategory))
                Text("Coding assistants first, generation credits below, with a hairline between.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show percentages", isOn: store.binding(\.showPercentages))
                Text("The number under each ring. Off leaves only the ring.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("The notch")
        }
    }
}

// MARK: - Secção 3 — Startup

struct StartupSection: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open Quotch at login", isOn: Binding(get: { enabled }, set: { setLogin($0) }))
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                } else {
                    Text("The notch is there from the moment you log in, with the readings already warm.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Startup")
        }
        .onAppear { enabled = SMAppService.mainApp.status == .enabled }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            enabled = on
            problem = nil
        } catch {
            enabled = SMAppService.mainApp.status == .enabled
            problem = "macOS refused this — try moving Quotch to /Applications."
        }
    }
}

// MARK: - Secção 4 — Updates
// Sparkle ainda não está no bundle; a secção compila sem ele e liga sozinha quando
// o framework entrar (ver tarefa "Sparkle" no relatório).

struct UpdatesSection: View {
    @AppStorage("SUAutomaticallyUpdate") private var automatic = true

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Install updates automatically", isOn: $automatic)
                Text("Version \(NQSettings.version). Updates install in the background and apply next time Quotch starts.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Check now") { NQUpdater.shared.checkForUpdates() }
                    .disabled(!NQUpdater.shared.isAvailable)
                if !NQUpdater.shared.isAvailable {
                    Text("Updates arrive with the next build.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Updates")
        }
    }
}

/// Fachada de updater. Sem Sparkle no bundle, `isAvailable` é falso e o botão fica inerte —
/// nada de crash e nada de texto mentindo.
final class NQUpdater {
    static let shared = NQUpdater()
    var isAvailable: Bool {
        NSClassFromString("SPUStandardUpdaterController") != nil
    }
    func checkForUpdates() {
        guard let cls = NSClassFromString("SPUStandardUpdaterController") as? NSObject.Type else { return }
        let controller = cls.init()
        let sel = NSSelectorFromString("checkForUpdates:")
        if controller.responds(to: sel) { _ = controller.perform(sel, with: nil) }
    }
}

// MARK: - Rodapé

struct CredentialsFooter: View {
    var body: some View {
        Section {
            Text(NQSettings.credentialsFooter)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text("App designed and developed by")
                if let link = NQSettings.authorLink {
                    Button(NQSettings.authorName) { NQLink.open(link) }.buttonStyle(.link)
                } else {
                    Text(NQSettings.authorName).fontWeight(.medium)
                }
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Seletor de navegador → perfil (contas de navegador)
struct BrowserPickerSheet: View {
    let kind: ProviderKind
    var onPick: (String) -> Void          // source: "<browserKey>:<profile>" ou "safari"
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable { let id = UUID(); let browserKey: String; let browserName: String; let profileDir: String; let profileName: String; let signedIn: Bool }
    @State private var rows: [Row] = []
    @State private var loading = true
    private func computeRows() -> [Row] {
        let sc = kind.sessionCookie
        var out: [Row] = []
        for b in ChromiumCookies.installed() {
            for p in ChromiumCookies.profiles(b) {
                let ok = sc.map { ChromiumCookies.hasCookie(host: $0.host, name: $0.name, browser: b, profile: p.dir) } ?? false
                out.append(Row(browserKey: b.key, browserName: b.name, profileDir: p.dir, profileName: p.name, signedIn: ok))
            }
        }
        // com sessão primeiro
        return out.sorted { ($0.signedIn ? 0:1, $0.browserName, $0.profileName) < ($1.signedIn ? 0:1, $1.browserName, $1.profileName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AccountGlyphChip(glyph: kind.defaultGlyph, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add a \(kind.displayName) account").font(.headline)
                    Text("Pick a browser you're already signed in to.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)

            if !BrowserAccess.hasFullDiskAccess() {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                        Text("Quotch needs Full Disk Access to read your browsers").font(.callout.weight(.medium))
                    }
                    Text("macOS blocks apps from reading another browser's session until you allow it. Turn on Quotch in Full Disk Access, then reopen this window — your browsers and profiles appear here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Full Disk Access settings") { BrowserAccess.openFullDiskAccessSettings() }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                .padding(.bottom, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text("Looking in your browsers…").foregroundStyle(.secondary) }
                    } else if rows.allSatisfy({ !$0.signedIn }) {
                        Text("No signed-in \(kind.displayName) session found. Sign in to \(kind.displayName) in any browser below, then reopen.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(rows) { r in
                        if r.signedIn {
                            pickRow(icon: "person.crop.circle.badge.checkmark", title: r.profileName, sub: r.browserName) {
                                onPick("\(r.browserKey):\(r.profileDir)"); dismiss()
                            }
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle").frame(width: 20).foregroundStyle(.tertiary)
                                Text(r.profileName).foregroundStyle(.secondary)
                                Text("\(r.browserName) · not signed in").font(.caption).foregroundStyle(.tertiary)
                                Spacer()
                            }.padding(.vertical, 6).padding(.horizontal, 8)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Safari").font(.subheadline.weight(.semibold))
                        if SafariCookies.readable {
                            pickRow(icon: "safari", title: "Safari", sub: "") { onPick("safari"); dismiss() }
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: "safari").frame(width: 20)
                                Text("Safari").foregroundStyle(.secondary)
                                Text("needs Full Disk Access").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Open Settings") {
                                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
                                }.controlSize(.small)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
                        }
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() } }.padding(.top, 10)
        }
        .padding(20)
        .frame(width: 420)
        .task { rows = computeRows(); loading = false }
    }

    @ViewBuilder private func pickRow(icon: String, title: String, sub: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle()).padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
        }
        .buttonStyle(.plain)
    }
}
