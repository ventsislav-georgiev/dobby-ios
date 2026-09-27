import SwiftUI
import WebKit

/// #237 Type on TV: pick a TV, pair by the code its Settings guide shows (once per TV), then the
/// TV's own phone page in a bare web view. Every text here is a fixed string or the TV's service
/// name; no address, port, token or code is ever shown or logged (guarded in run-checks.sh).
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
            TvLinkPage(url: page, unpaired: unpaired)
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
        case .refused:
            note = "The TV refused the pairing. Try again."
        }
    }

    /// The page saw a 401: the TV forgot this phone.
    private func unpaired() {
        guard let tv else { return }
        _ = TvLink.answered(401, tv: tv.name, store: TvLink.store)
        page = nil
        note = "The TV forgot this phone. Enter a new code."
        askCode = true
    }
}

/// The TV's phone page, with no address bar. Nothing persists (a non-persistent data store), and
/// a 401 from any of the page's own calls is reported back so the token is dropped.
struct TvLinkPage {
    let url: URL
    let unpaired: () -> Void

    static let watch401 = """
    (function () {
      var fetch = window.fetch;
      window.fetch = function () {
        return fetch.apply(this, arguments).then(function (response) {
          if (response.status === 401) window.webkit.messageHandlers.tvLink.postMessage('401');
          return response;
        });
      };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let unpaired: () -> Void
        init(unpaired: @escaping () -> Void) { self.unpaired = unpaired }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.body as? String == "401" { unpaired() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(unpaired: unpaired) }

    fileprivate func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(coordinator, name: "tvLink")
        config.userContentController.addUserScript(
            WKUserScript(source: Self.watch401, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }
}

#if os(macOS)
extension TvLinkPage: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension TvLinkPage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
