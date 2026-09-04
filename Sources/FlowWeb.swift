import AppKit
import WebKit

/// Conexão por LOGIN DENTRO DO APP. Cada conta tem um WKWebView com sessão isolada
/// (WKWebsiteDataStore por conta). Você entra uma vez; a leitura usa a sessão viva,
/// via fetch same-origin na própria página. Não precisa de Full Disk Access, nem ler
/// o Chrome/Safari de fora, nem Keychain. É o caminho confiável e whitelabel.
@MainActor
final class WebSession: NSObject {
    static let shared = WebSession()

    private final class Session {
        let webview: WKWebView
        let host: NSWindow          // janela oculta que mantém o webview carregado
        init(webview: WKWebView, host: NSWindow) { self.webview = webview; self.host = host }
    }
    private var sessions: [UUID: Session] = [:]
    private var signInWindow: NSWindow?

    private func siteURL(_ kind: ProviderKind) -> URL {
        switch kind {
        case .flow:   return URL(string: "https://labs.google/fx/tools/flow")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        default:      return URL(string: "https://claude.ai/settings/usage")!
        }
    }

    private func session(_ id: UUID, _ kind: ProviderKind) -> Session {
        if let s = sessions[id] { return s }
        let cfg = WKWebViewConfiguration()
        if #available(macOS 14.0, *) { cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: id) }
        if kind == .flow {
            let js = "(function(){const g=(t)=>{try{const j=JSON.parse(t.replace(/^\\)\\]}'\\s*/,''));if(/credit/i.test(JSON.stringify(j))){window.__nqC=window.__nqC||[];window.__nqC.push(j);}}catch(e){}};const of=window.fetch;window.fetch=function(){return of.apply(this,arguments).then(r=>{try{r.clone().text().then(g);}catch(e){}return r;});};const oo=XMLHttpRequest.prototype.open,os=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.open=function(){this.__nqTrack=true;return oo.apply(this,arguments);};XMLHttpRequest.prototype.send=function(){if(this.__nqTrack)this.addEventListener('load',()=>g(this.responseText));return os.apply(this,arguments);};})();"
            cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: cfg)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        // janela oculta (fora da tela) só para manter o webview vivo/carregado
        let host = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 760),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = wv
        host.orderFrontRegardless()
        let s = Session(webview: wv, host: host)
        sessions[id] = s
        wv.load(URLRequest(url: siteURL(kind)))
        return s
    }

    /// Janela de login. Reaproveita o mesmo webview da sessão (isola cookies por conta).
    func signIn(accountID: UUID, kind: ProviderKind, onDone: @escaping (Bool) -> Void) {
        let s = session(accountID, kind)
        s.webview.load(URLRequest(url: siteURL(kind)))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in — \(kind.displayName)"
        w.contentView = s.webview
        w.center(); w.level = .floating; w.isReleasedWhenClosed = false
        signInWindow = w
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self, weak s] _ in
            guard let self, let s else { return }
            // devolve o webview para a janela oculta e tenta ler
            s.host.contentView = s.webview
            s.host.orderFrontRegardless()
            Task { @MainActor in onDone((try? await self.read(accountID: accountID, kind: kind)) != nil) }
        }
    }

    func identity(accountID: UUID, kind: ProviderKind) async -> AccountIdentity? {
        guard kind != .flow else { return nil }
        let s = session(accountID, kind)
        try? await ready(s)
        let js = "try{const r=await fetch('/api/bootstrap',{headers:{'anthropic-client-platform':'web_claude_ai'}});const j=await r.json();const a=j.account||{};return JSON.stringify({email:a.email_address||a.email||null,name:a.full_name||a.display_name||null});}catch(e){return 'ERR'}"
        guard let out = try? await s.webview.callAsyncJavaScript(js, contentWorld: .page) as? String,
              out.hasPrefix("{"), let d = out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return AccountIdentity(email: j["email"] as? String, name: j["name"] as? String, plan: nil)
    }

    func read(accountID: UUID, kind: ProviderKind) async throws -> UsageReading {
        let s = session(accountID, kind)
        try? await ready(s)
        switch kind {
        case .flow:   return try await readFlow(s.webview)
        case .cursor: return try await readCursor(s.webview)
        default:      return try await readClaude(s.webview)
        }
    }

    /// Espera a página carregar (a sessão viva).
    private func ready(_ s: Session) async throws {
        for _ in 0..<10 {
            if s.webview.url != nil && !s.webview.isLoading { return }
            try? await sleep(0.4)
        }
    }

    private func readClaude(_ wv: WKWebView) async throws -> UsageReading {
        let js = """
        try {
          let org = (document.cookie.match(/lastActiveOrg=([^;]+)/)||[])[1];
          if (!org) { const o = await (await fetch('/api/organizations',{headers:{'anthropic-client-platform':'web_claude_ai'}})).json(); org = (o&&o[0]&&(o[0].uuid||o[0].id)); }
          if (!org) return 'NOORG';
          const r = await fetch('/api/organizations/'+org+'/usage?source=web',{headers:{'anthropic-client-platform':'web_claude_ai'}});
          if (r.status !== 200) return 'HTTP'+r.status;
          return JSON.stringify(await r.json());
        } catch(e) { return 'ERR '+e; }
        """
        let out = try await wv.callAsyncJavaScript(js, contentWorld: .page) as? String
        guard let out, out.hasPrefix("{"), let d = out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw ProviderError.badResponse("Claude: \(out ?? "sign in")")
        }
        return Providers.parseClaudeUsage(j)
    }

    private func readCursor(_ wv: WKWebView) async throws -> UsageReading {
        let js = "try{const r=await fetch('/api/usage-summary');if(r.status!==200)return 'HTTP'+r.status;return JSON.stringify(await r.json());}catch(e){return 'ERR '+e;}"
        let out = try await wv.callAsyncJavaScript(js, contentWorld: .page) as? String
        guard let out, out.hasPrefix("{"), let d = out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw ProviderError.badResponse("Cursor: \(out ?? "sign in")")
        }
        let iu = j["individualUsage"] as? [String: Any]; let plan = iu?["plan"] as? [String: Any]
        let pct = (plan?["totalPercentUsed"] as? Double) ?? 0
        return UsageReading(fraction: pct/100, windows: [QuotaWindow(label:"Included usage", resetText:"", fraction: pct/100)], fetchedAt: Date())
    }

    private func readFlow(_ wv: WKWebView) async throws -> UsageReading {
        for _ in 0..<8 {
            let js = """
            let credits=null,subscriptionCredits=null,topUpCredits=null,explicitTotal=null,serviceTier=null,paygateTier=null,sku=null;
            for(const j of (window.__nqC||[])){const walk=(o)=>{if(!o||typeof o!=='object')return;for(const k in o){const v=o[k];
              if(k==='credits'&&typeof v==='number')credits=v;
              if(k==='subscriptionCredits'&&typeof v==='number')subscriptionCredits=v;
              if(k==='topUpCredits'&&typeof v==='number')topUpCredits=v;
              if(/^(totalCredits|creditLimit|monthlyCredits|monthlyAllowance)$/i.test(k)&&typeof v==='number')explicitTotal=v;
              if(k==='serviceTier'&&typeof v==='string')serviceTier=v;
              if(/^(paygateTier|userPaygateTier)$/i.test(k)&&typeof v==='string')paygateTier=v;
              if(k==='sku'&&typeof v==='string')sku=v;
              walk(v);
            }};walk(j);}
            return JSON.stringify({credits,subscriptionCredits,topUpCredits,explicitTotal,serviceTier,paygateTier,sku,debugUrl:location.href,debugCaptured:(window.__nqC||[]).length});
            """
            if let out = try await wv.callAsyncJavaScript(js, contentWorld: .page) as? String,
               let d = out.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                QTLog.write("Flow web url=\(j["debugUrl"] as? String ?? "?") captured=\((j["debugCaptured"] as? NSNumber)?.intValue ?? 0)")
                if let reading = Providers.parseFlowCredits(j) { return reading }
            }
            try? await sleep(1.0)
        }
        throw ProviderError.badResponse("Flow: sign in again")
    }

    private func sleep(_ s: Double) async throws { try await Task.sleep(nanoseconds: UInt64(s*1e9)) }
}
enum FlowWeb { @MainActor static var shared: WebSession { WebSession.shared } }
