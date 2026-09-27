import SwiftUI
import WebKit
#if os(iOS)
import AVFoundation
#endif

/// #237 Type on TV: pick a TV, pair by the code its Settings guide shows (once per TV), then the
/// TV's own phone page in a bare web view. Every text here is a fixed string or the TV's service
/// name; no address, port, token or code is ever shown or logged (guarded in run-checks.sh).
/// A rotated token: the TV's page shows its own "pair again" status on a 401, and the next open's
/// GET /v1/state probe drops the token and key items (TvLink.answered). No WKWebView hook can do more:
/// with App-Bound Domains on, iOS turns off user scripts and message handlers on a LAN origin.
/// #248, iOS only: the pair step offers Scan QR code before the code, and the page of a code-only
/// pairing offers it in the toolbar; a scan of the picked TV's QR keeps the token and the settings
/// key and opens the page with both. The payload and the key are never shown or logged either.
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
    @State private var scanning = false
    @State private var keyed = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Type on TV")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    #if os(iOS)
                    ToolbarItem(placement: .primaryAction) {
                        if scanning {
                            Button("Cancel") { scanning = false }
                        } else if page != nil && !keyed {
                            Button("Scan QR code") { Task { await scan() } }
                        }
                    }
                    #endif
                }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        if scanning {
            TvLinkScanner(found: scanned)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("Point the camera at the QR code in the TV's Settings.")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
        } else {
            steps
        }
        #else
        steps
        #endif
    }

    @ViewBuilder private var steps: some View {
        if let page {
            TvLinkPage(url: page)
                .safeAreaInset(edge: .bottom) {
                    if let note { Text(note) }
                }
        } else if askCode {
            Form {
                #if os(iOS)
                Section {
                    Button("Scan QR code") { Task { await scan() } }
                        .disabled(busy)
                } footer: {
                    Text("Scan the QR code in the TV's Settings so this phone can send Settings too.")
                }
                #endif
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
        switch TvLink.saved(TvLink.store.read(found.name), key: TvLink.store.readKey(found.name)) {
        case .refused:
            note = "Dobby could not read this TV's pairing. Unlock the phone and try again."
        case .none:
            askCode = true
        case .token(let token, let key):
            guard let http = await TvLink.probe(token: token, at: address) else {
                note = "That TV did not answer. Is Dobby open on it?"
                return
            }
            if http == 429 {
                note = "The TV is busy. Wait a minute and try again."
                return
            }
            if TvLink.answered(http, tv: found.name, store: TvLink.store) {
                keyed = key != nil
                page = TvLink.url(address, token: token, key: key)
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

    #if os(iOS)
    @MainActor private func scan() async {
        note = nil
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            note = "Dobby cannot use the camera. Allow Camera for Dobby in Settings."
            return
        }
        scanning = true
    }

    /// The scanner's one read: kept only when it is the picked TV's QR (TvLink.keep).
    @MainActor private func scanned(_ payload: String?) {
        scanning = false
        guard let tv, let at else { return }
        guard let payload else {
            note = "Dobby cannot use the camera on this device."
            return
        }
        switch TvLink.keep(payload, tv: tv.name, at: at, store: TvLink.store) {
        case .kept(let token, let key):
            note = nil
            keyed = true
            page = TvLink.url(at, token: token, key: key)
        case .otherTv:
            note = "That QR code is from another TV."
        case .notALink:
            note = "That QR code is not from Dobby on a TV."
        }
    }
    #endif
}

#if os(iOS)
/// #248: the camera, reading one QR code. startRunning blocks, so the session starts and stops on
/// its own queue, never main; the first QR read stops it and goes to `found`, never shown or
/// logged. nil is a camera the app cannot use (none, as in the simulator, or its input refused).
struct TvLinkScanner: UIViewControllerRepresentable {
    let found: (String?) -> Void

    func makeUIViewController(context: Context) -> Camera { Camera(found: found) }
    func updateUIViewController(_ camera: Camera, context: Context) {}
    static func dismantleUIViewController(_ camera: Camera, coordinator: ()) { camera.stop() }

    final class Camera: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let found: (String?) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "tv-link.scan")
        private var preview: AVCaptureVideoPreviewLayer?
        private var read = false

        init(found: @escaping (String?) -> Void) {
            self.found = found
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let output = AVCaptureMetadataOutput()
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input), session.canAddOutput(output) else {
                DispatchQueue.main.async { self.finish(nil) }
                return
            }
            session.addInput(input)
            session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                DispatchQueue.main.async { self.finish(nil) }
                return
            }
            output.metadataObjectTypes = [.qr]
            output.setMetadataObjectsDelegate(self, queue: .main)
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            self.preview = preview
            queue.async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
            finish(code)
        }

        private func finish(_ payload: String?) {
            guard !read else { return }
            read = true
            stop()
            found(payload)
        }

        func stop() { queue.async { [session] in session.stopRunning() } }
    }
}
#endif

/// The TV's phone page, with no address bar, and nothing persists. A 401 is the page's own to
/// show; the Keychain items go on the next open's probe (see TvLinkSheet).
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
