import AppKit
import SwiftUI
import WebKit
import PMD3BarCore

/// Controls a viewer web view from SwiftUI (recording, reload).
@MainActor
@Observable
final class ViewerController {
    enum Recording: Equatable { case idle, recording(since: Date), saving }

    var recording: Recording = .idle
    var lastError: String?
    /// Name used for screenshots/recordings saved from this viewer.
    var deviceName = "iPhone"
    /// Only the iPhone, without the viewer's top bar, side trays and button row. The default;
    /// the choice is remembered for the next windows.
    var deviceOnly: Bool = true {
        didSet {
            if let key = modeKey { UserDefaults.standard.set(deviceOnly, forKey: key) }
            applyLayout()
        }
    }
    /// Where this iPhone's mode is remembered (nil for the grid, which always shows only the iPhones).
    @ObservationIgnored private let modeKey: String?

    /// - udid: remember "only the iPhone" / "controls" for this iPhone (default: only the iPhone).
    /// - deviceOnly: fixed mode, not remembered (grid).
    init(udid: String? = nil, deviceOnly fixed: Bool? = nil) {
        modeKey = fixed == nil ? udid.map { "deviceOnly.\($0)" } : nil
        if let fixed {
            deviceOnly = fixed
        } else if let key = modeKey, let saved = UserDefaults.standard.object(forKey: key) as? Bool {
            deviceOnly = saved
        } else {
            // Before per-iPhone memory there was one setting for every window.
            deviceOnly = UserDefaults.standard.object(forKey: "deviceOnly") as? Bool ?? true
        }
    }
    fileprivate weak var webView: WKWebView?
    /// Width / height of the iPhone screen as streamed (changes with rotation).
    private(set) var canvasRatio: Double?
    /// Called when the screen proportions change (window sizing).
    var onCanvasRatio: ((Double) -> Void)?

    fileprivate func canvasRatioChanged(_ ratio: Double) {
        canvasRatio = ratio
        onCanvasRatio?(ratio)
    }

    /// Device frame and screen in web view coordinates (top-left origin), as last laid out.
    @ObservationIgnored fileprivate var deviceFrame: CGRect?
    @ObservationIgnored fileprivate var screenFrame: CGRect?
    /// Called after the device was laid out again (the window shadow follows its shape).
    @ObservationIgnored var onLayout: (() -> Void)?

    fileprivate func geometryChanged(_ json: String) {
        struct Geometry: Decodable { let frame: [Double]; let screen: [Double] }
        guard let data = json.data(using: .utf8),
              let g = try? JSONDecoder().decode(Geometry.self, from: data),
              g.frame.count == 4, g.screen.count == 4 else { return }
        func rect(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
        deviceFrame = rect(g.frame)
        screenFrame = rect(g.screen)
        onLayout?()
    }

    /// True when a click at `point` (top-left origin) lands on the bezel: the device frame
    /// outside the screen. The hardware buttons sit outside the frame and keep working.
    fileprivate func isOnBezel(_ point: CGPoint) -> Bool {
        guard deviceOnly, let deviceFrame, let screenFrame else { return false }
        return deviceFrame.contains(point) && !screenFrame.contains(point)
    }

    fileprivate func applyLayout() {
        webView?.evaluateJavaScript("window.__pmd3barLayout && window.__pmd3barLayout.setDeviceOnly(\(deviceOnly))")
    }

    func startRecording() {
        webView?.evaluateJavaScript("window.__pmd3bar.startRecording()") { [weak self] result, error in
            MainActor.assumeIsolated {
                if let error { self?.lastError = error.localizedDescription; return }
                if let msg = result as? String, !msg.isEmpty { self?.lastError = msg; return }
                self?.recording = .recording(since: Date())
            }
        }
    }

    func stopRecording() {
        guard case .recording = recording else { return }
        recording = .saving
        let name = Self.fileStem(deviceName)
        webView?.evaluateJavaScript("window.__pmd3bar.stopRecording(\(Self.jsString(name)))")
    }

    func reload() { webView?.reload() }

    fileprivate func recordingFinished(_ error: String?) {
        recording = .idle
        lastError = error
    }

    static func fileStem(_ device: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let clean = device.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(clean) \(f.string(from: Date()))"
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}

/// Web view that moves its window when the iPhone's bezel is dragged, like the Simulator: with
/// only the iPhone showing, the bezel is most of what there is to grab.
final class ViewerWKWebView: WKWebView {
    weak var controller: ViewerController?

    override func mouseDown(with event: NSEvent) {
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        if let window, controller?.isOnBezel(p) == true {
            window.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

/// WKWebView hosting the serve-web viewer: plays audio without a click, saves the viewer's
/// downloads (screenshots, recordings) into ~/Downloads, and forwards console errors to our log.
struct ViewerWebView: NSViewRepresentable {
    let url: URL
    /// Changes whenever the viewer must be reloaded (serve-web restarted).
    let generation: Int
    let controller: ViewerController
    /// Answers serve-web's password challenge. nil until the session has verified that the port is
    /// held by its own serve-web.
    let credential: URLCredential?

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let ucc = config.userContentController
        ucc.add(context.coordinator, name: "pmd3bar")
        ucc.addUserScript(WKUserScript(source: Self.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Self.layoutJS(deviceOnly: controller.deviceOnly),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = ViewerWKWebView(frame: .zero, configuration: config)
        web.controller = controller
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isInspectable = true  // Safari ▸ Develop menu, for debugging the viewer
        web.setValue(false, forKey: "drawsBackground")
        controller.webView = web
        context.coordinator.loadedGeneration = generation
        context.coordinator.viewerURL = url
        context.coordinator.credential = credential
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        controller.webView = web
        context.coordinator.viewerURL = url
        context.coordinator.credential = credential
        if context.coordinator.loadedGeneration != generation || web.url?.port != url.port {
            context.coordinator.loadedGeneration = generation
            web.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "pmd3bar")
        web.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        let controller: ViewerController
        var loadedGeneration = -1
        var viewerURL: URL?
        var credential: URLCredential?

        private var viewerPort: Int { viewerURL?.port ?? -1 }

        /// serve-web asks for its password: answer only for this viewer's exact host and port.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic, space.host == "127.0.0.1",
               space.port == viewerPort, space.protocol == "http", challenge.previousFailureCount == 0,
               let credential {
                completionHandler(.useCredential, credential)
            } else if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        init(controller: ViewerController) { self.controller = controller }

        // Messages from the injected bridge script.
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            let text = body["text"] as? String ?? ""
            MainActor.assumeIsolated {
                switch kind {
                case "log": PMD3.log("[viewer] \(text)")
                case "ratio": if let r = Double(text), r > 0 { controller.canvasRatioChanged(r) }
                case "geometry": controller.geometryChanged(text)
                case "recording-done": controller.recordingFinished(nil)
                case "recording-error":
                    PMD3.log("[viewer] recording: \(text)")
                    controller.recordingFinished(text)
                default: break
                }
            }
        }

        // Downloads (the viewer saves screenshots via <a download>, we do the same for recordings).
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let inViewer = Safety.isViewerURL(url, port: viewerPort)
                || ["about", "blob", "data"].contains(url.scheme ?? "")
            if action.shouldPerformDownload {
                decisionHandler(inViewer ? .download : .cancel)
            } else if inViewer && action.targetFrame != nil {
                decisionHandler(.allow)
            } else {
                // Leaving the viewer: only a link the user clicked, to a web or mail address, goes to
                // the default browser. Never file:, apps or custom schemes, never a scripted redirect.
                if !inViewer, Safety.mayOpenExternally(url, userClicked: action.navigationType == .linkActivated) {
                    NSWorkspace.shared.open(url)
                } else if !inViewer {
                    PMD3.log("[viewer] blocked navigation to \(url.scheme ?? "?"):…")
                }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let name = Safety.fileName((suggestedFilename as NSString).lastPathComponent, fallback: "iPhone")
            let dest = uniqueURL(downloads.appendingPathComponent(name))
            pendingDestinations[ObjectIdentifier(download)] = dest
            completionHandler(dest)
        }

        private var pendingDestinations: [ObjectIdentifier: URL] = [:]

        func downloadDidFinish(_ download: WKDownload) {
            if let dest = pendingDestinations.removeValue(forKey: ObjectIdentifier(download)) {
                markQuarantined(dest)
                PMD3.log("Saved \(dest.path)")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            pendingDestinations.removeValue(forKey: ObjectIdentifier(download))
            PMD3.log("Download failed: \(error.localizedDescription)")
        }

        // A reload (serve-web restarted) gets the mode from when the view was made: re-apply the current one.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { controller.applyLayout() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            PMD3.log("[viewer] load failed: \(error.localizedDescription)")
        }
    }

    /// Viewer layout, injected at document start:
    /// - always hides the pymobiledevice3 branding (logo + name) in the top bar;
    /// - "device only" mode (`html.pmd3-device-only`) hides the top bar, both side trays and the
    ///   button row, and makes the page transparent around the device (no background, glow or
    ///   drop shadow), so the window can take the iPhone's shape. The viewer's
    ///   fitCanvasToViewport() keeps 150 px of height and 88 px of width for its own chrome: in
    ///   this mode it is shown a viewport that only keeps our margin, for the duration of the
    ///   call, so the device fills the window. `make check` verifies what this relies on.
    /// - reports the screen proportions (window sizing) and where the bezel is (window dragging).
    static func layoutJS(deviceOnly: Bool) -> String {
        let m = Int(ViewerLayout.margin)
        return """
        (() => {
          const style = document.createElement('style');
          style.textContent = `
            #brand-logo, #brand { display: none !important; }
            html.pmd3-device-only #topbar,
            html.pmd3-device-only .tray,
            html.pmd3-device-only #bottom-row { display: none !important; }
            html.pmd3-device-only, html.pmd3-device-only body { background: transparent !important; }
            html.pmd3-device-only body { padding: 0; gap: 0; overflow: hidden; }
            html.pmd3-device-only #workspace { gap: 0; align-items: center; }
            html.pmd3-device-only #stage-wrap { padding: \(m)px; }
            html.pmd3-device-only #stage::before { display: none; }
            html.pmd3-device-only body.frame-on #device-frame { box-shadow: 0 0 0 2px #55585f, 0 0 0 3px #1b1c1f; }
          `;
          document.documentElement.appendChild(style);

          let deviceOnly = \(deviceOnly);
          document.documentElement.classList.toggle('pmd3-device-only', deviceOnly);

          const VIEWER_RESERVED_W = \(Int(ViewerLayout.viewerReservedWidth)), OWN_RESERVED_W = \(Int(ViewerLayout.reservedWidth));
          const VIEWER_RESERVED_H = \(Int(ViewerLayout.viewerReservedHeight)), OWN_RESERVED_H = \(Int(ViewerLayout.ownReservedHeight));
          const post = (kind, text) => {
            try { window.webkit.messageHandlers.pmd3bar.postMessage({kind, text: String(text)}); } catch (_) {}
          };
          // Tells the app the screen proportions, so the window can be sized around the iPhone.
          let lastRatio = 0;
          const reportRatio = () => {
            const c = document.getElementById('c');
            if (!c || !c.width || !c.height) return;
            const r = c.width / c.height;
            if (Math.abs(r - lastRatio) < 0.001) return;
            lastRatio = r;
            post('ratio', r);
          };
          // Tells the app where the device frame and the screen are, so dragging the bezel moves the window.
          let lastGeometry = '';
          const reportGeometry = () => {
            const f = document.getElementById('device-frame'), c = document.getElementById('c');
            if (!f || !c) return;
            const box = r => [r.left, r.top, r.width, r.height].map(v => Math.round(v * 10) / 10);
            const g = JSON.stringify({frame: box(f.getBoundingClientRect()), screen: box(c.getBoundingClientRect())});
            if (g === lastGeometry) return;
            lastGeometry = g;
            post('geometry', g);
          };
          const install = () => {
            const orig = window.fitCanvasToViewport;
            if (typeof orig !== 'function' || orig.__pmd3bar) return;
            const fit = function () {
              try { return fitInner(); } finally { reportRatio(); requestAnimationFrame(reportGeometry); }
            };
            const fitInner = function () {
              if (!deviceOnly) return orig();
              const own = {h: Object.getOwnPropertyDescriptor(window, 'innerHeight'),
                           w: Object.getOwnPropertyDescriptor(window, 'innerWidth')};
              const h = window.innerHeight, w = window.innerWidth;
              Object.defineProperty(window, 'innerHeight',
                                    {get: () => h + VIEWER_RESERVED_H - OWN_RESERVED_H, configurable: true});
              Object.defineProperty(window, 'innerWidth',
                                    {get: () => w + VIEWER_RESERVED_W - OWN_RESERVED_W, configurable: true});
              try { orig(); } finally {
                if (own.h) Object.defineProperty(window, 'innerHeight', own.h); else delete window.innerHeight;
                if (own.w) Object.defineProperty(window, 'innerWidth', own.w); else delete window.innerWidth;
              }
            };
            fit.__pmd3bar = true;
            window.fitCanvasToViewport = fit;   // the viewer's own calls go through the global name
            window.addEventListener('resize', fit);  // runs after the viewer's original listener
            fit();
          };
          window.addEventListener('DOMContentLoaded', install);
          window.__pmd3barLayout = {
            setDeviceOnly(on) {
              deviceOnly = on;
              document.documentElement.classList.toggle('pmd3-device-only', on);
              install();
              if (typeof window.fitCanvasToViewport === 'function') window.fitCanvasToViewport();
            },
          };
        })();
        """
    }

    /// Injected into the viewer: forwards console warnings/errors and records the screen canvas.
    /// The recording includes the iPhone's audio when the viewer is playing it (audio tap below).
    static let bridgeJS = #"""
    (() => {
      const post = (kind, text) => {
        try { window.webkit.messageHandlers.pmd3bar.postMessage({kind, text: String(text)}); } catch (_) {}
      };
      for (const level of ['warn', 'error']) {
        const orig = console[level].bind(console);
        console[level] = (...args) => { orig(...args); post('log', level + ': ' + args.join(' ')); };
      }
      window.addEventListener('error', e => post('log', 'error: ' + e.message));
      window.addEventListener('DOMContentLoaded', () => {
        post('log', 'WebCodecs VideoDecoder: ' + (typeof VideoDecoder !== 'undefined'));
      });

      // Audio tap: the viewer plays sound by connecting nodes to its AudioContext's destination.
      // Every such connection is mirrored into a MediaStream the recorder can add as a track.
      const origConnect = AudioNode.prototype.connect;
      AudioNode.prototype.connect = function (target, ...rest) {
        const result = origConnect.call(this, target, ...rest);
        try {
          const ctx = this.context;
          if (target === ctx.destination) {
            if (!ctx.__pmd3barTap) ctx.__pmd3barTap = ctx.createMediaStreamDestination();
            window.__pmd3barAudioTap = ctx.__pmd3barTap;
            origConnect.call(this, ctx.__pmd3barTap);
          }
        } catch (_) {}
        return result;
      };

      let recorder = null, chunks = [], mime = '';
      window.__pmd3bar = {
        startRecording() {
          const canvas = document.getElementById('c');
          if (!canvas || !canvas.captureStream) return 'Schermo non disponibile per la registrazione';
          if (typeof MediaRecorder === 'undefined') return 'Registrazione non supportata';
          const stream = canvas.captureStream(30);
          const tap = window.__pmd3barAudioTap;
          const audio = tap && tap.context.state !== 'closed' ? tap.stream.getAudioTracks() : [];
          audio.forEach(t => stream.addTrack(t));
          const types = audio.length
            ? ['video/mp4;codecs=avc1,mp4a.40.2', 'video/mp4', 'video/webm;codecs=vp8,opus', 'video/webm']
            : ['video/mp4;codecs=avc1', 'video/mp4', 'video/webm'];
          mime = types.find(t => MediaRecorder.isTypeSupported(t)) || '';
          chunks = [];
          try {
            recorder = new MediaRecorder(stream, mime ? {mimeType: mime, videoBitsPerSecond: 8000000, audioBitsPerSecond: 160000} : {});
          } catch (e) { return 'Registrazione non avviata: ' + e.message; }
          post('log', 'registrazione: ' + (mime || 'formato predefinito') + (audio.length ? ', con audio' : ', senza audio (audio del viewer non attivo)'));
          recorder.ondataavailable = e => { if (e.data && e.data.size) chunks.push(e.data); };
          recorder.onerror = e => post('recording-error', e.error ? e.error.message : 'errore');
          recorder.start(1000);
          return '';
        },
        stopRecording(stem) {
          if (!recorder) { post('recording-error', 'nessuna registrazione attiva'); return; }
          recorder.onstop = () => {
            const type = recorder.mimeType || mime || 'video/mp4';
            const blob = new Blob(chunks, {type});
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = stem + (type.includes('webm') ? '.webm' : '.mp4');
            document.body.appendChild(a); a.click(); a.remove();
            setTimeout(() => URL.revokeObjectURL(a.href), 60000);
            recorder = null; chunks = [];
            post('recording-done', '');
          };
          recorder.stop();
        },
      };
    })();
    """#
}
