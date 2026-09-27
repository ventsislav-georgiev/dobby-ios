import SwiftUI
import WebKit

/// #237 Type on TV: pick a TV, pair by the code its Settings guide shows (once per TV), then the
/// TV's own phone page in a bare web view. Every text here is a fixed string or the TV's service
/// name; no address, port, token or code is ever shown or logged (guarded in run-checks.sh).
/// A rotated token: the TV's page shows its own "pair again" status on a 401, and the next open's
/// GET /v1/state probe drops the Keychain item (TvLink.answered). No WKWebView hook can do more:
/// with App-Bound Domains on, iOS turns off user scripts and message handlers on a LAN origin.
struct TvLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = TvLinkBrowser()
    @State private var tv: TvLinkBrowser.Tv?
    @State private var at: TvLink.Address?
    @State private var askCode = false
    @State private var code = ""
    @State private var page: URL?
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Type on TV")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    @ViewBuilder private var content: some View {
        if let page {
            TvLinkPage(url: page)
        } else if askCode {
            Form {
                Section {
                    TextField("Code", text: $code)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Button("Pair") { Task { await pair() } }
                        .disabled(busy || !TvLink.isCode(code))
                } footer: {
                    Text("Open Settings on the TV and enter the 6-digit code it shows.")
                }
                if let note { Text(note) }
            }
        } else {
            List {
                ForEach(browser.tvs) { found in
                    Button(found.name) { Task { await open(found) } }
                }
                if browser.tvs.isEmpty {
                    Text(browser.failed ? "Dobby cannot look for TVs. Allow Local Network for Dobby in Settings."
                                        : "Looking for Dobby on a TV. Open Dobby on the TV first.")
                }
                if let note { Text(note) }
            }
            .disabled(busy)
        }
    }

    @MainActor private func open(_ found: TvLinkBrowser.Tv) async {
        busy = true
        defer { busy = false }
        note = nil
        tv = found
        guard let address = await TvLink.resolve(found.endpoint) else {
            note = "That TV did not answer. Is Dobby open on it?"
            return
        }
        at = address
        switch TvLink.saved(TvLink.store.read(found.name)) {
        case .refused:
            note = "Dobby could not read this TV's pairing. Unlock the phone and try again."
        case .none:
            askCode = true
        case .token(let token):
            guard let http = await TvLink.probe(token: token, at: address) else {
                note = "That TV did not answer. Is Dobby open on it?"
                return
            }
            if http == 429 {
                note = "The TV is busy. Wait a minute and try again."
                return
            }
            if TvLink.answered(http, tv: found.name, store: TvLink.store) {
                page = TvLink.url(address, token: token)
            } else {
                note = "The TV forgot this phone. Enter a new code."
                askCode = true
            }
        }
    }

    @MainActor private func pair() async {
        guard let tv, let at else { return }
        busy = true
        defer { busy = false }
        guard let answer = await TvLink.pair(code: code, at: at) else {
            note = "That TV did not answer. Is Dobby open on it?"
            return
        }
        code = ""
        switch answer {
        case .paired:
            note = nil
            page = TvLink.settle(answer, tv: tv.name, store: TvLink.store).flatMap { TvLink.url(at, token: $0) }
        case .wrongCode:
            note = "Wrong code. Check the TV and try again."
        case .closed:
            note = "Open Settings on the TV so it shows a code."
        case .busy:
            note = "The TV is busy. Wait a minute and try again."
        case .refused:
            note = "The TV refused the pairing. Try again."
        }
    }
}

/// The TV's phone page, with no address bar, and nothing persists. A 401 is the page's own to
/// show; the Keychain item goes on the next open's probe (see TvLinkSheet).
struct TvLinkPage {
    let url: URL

    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return config
    }

    fileprivate func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.configuration())
        webView.load(URLRequest(url: url))
        return webView
    }
}

#if os(macOS)
extension TvLinkPage: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension TvLinkPage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
