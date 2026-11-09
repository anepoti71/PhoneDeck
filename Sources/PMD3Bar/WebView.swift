import AppKit
import SwiftUI
import WebKit

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
    var deviceOnly: Bool = UserDefaults.standard.object(forKey: "deviceOnly") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(deviceOnly, forKey: "deviceOnly")
            applyLayout()
        }
    }
    fileprivate weak var webView: WKWebView?

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
        f.dateFormat = "yyyy-MM-dd 'alle' HH.mm.ss"
        let clean = device.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(clean) \(f.string(from: Date()))"
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}

/// WKWebView hosting the serve-web viewer: plays audio without a click, saves the viewer's
/// downloads (screenshots, recordings) into ~/Downloads, and forwards console errors to our log.
struct ViewerWebView: NSViewRepresentable {
    let url: URL
    /// Changes whenever the viewer must be reloaded (serve-web restarted).
    let generation: Int
    let controller: ViewerController

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

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isInspectable = true  // Safari ▸ Develop menu, for debugging the viewer
        web.setValue(false, forKey: "drawsBackground")
        controller.webView = web
        context.coordinator.loadedGeneration = generation
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        controller.webView = web
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

        init(controller: ViewerController) { self.controller = controller }

        // Messages from the injected bridge script.
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            let text = body["text"] as? String ?? ""
            MainActor.assumeIsolated {
                switch kind {
                case "log": PMD3.log("[viewer] \(text)")
                case "recording-done": controller.recordingFinished(nil)
                case "recording-error":
                    PMD3.log("[viewer] registrazione: \(text)")
                    controller.recordingFinished(text)
                default: break
                }
            }
        }

        // Downloads (the viewer saves screenshots via <a download>, we do the same for recordings).
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.shouldPerformDownload {
                decisionHandler(.download)
            } else if let url = action.request.url, action.targetFrame == nil || url.host != "127.0.0.1" {
                // Links leaving the viewer open in the default browser.
                if url.host != "127.0.0.1" { NSWorkspace.shared.open(url); decisionHandler(.cancel) } else { decisionHandler(.allow) }
            } else {
                decisionHandler(.allow)
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
            let name = suggestedFilename.isEmpty ? "iPhone" : suggestedFilename
            let dest = uniqueURL(downloads.appendingPathComponent(name))
            pendingDestinations[ObjectIdentifier(download)] = dest
            completionHandler(dest)
        }

        private var pendingDestinations: [ObjectIdentifier: URL] = [:]

        func downloadDidFinish(_ download: WKDownload) {
            if let dest = pendingDestinations.removeValue(forKey: ObjectIdentifier(download)) {
                PMD3.log("Salvato \(dest.path)")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            pendingDestinations.removeValue(forKey: ObjectIdentifier(download))
            PMD3.log("Download fallito: \(error.localizedDescription)")
        }

        // A reload (serve-web restarted) gets the mode from when the view was made: re-apply the current one.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { controller.applyLayout() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            PMD3.log("[viewer] caricamento fallito: \(error.localizedDescription)")
        }
    }

    /// Viewer layout, injected at document start:
    /// - always hides the pymobiledevice3 branding (logo + name) in the top bar;
    /// - "device only" mode (`html.pmd3-device-only`) hides the top bar, both side trays and the
    ///   button row, leaving just the iPhone. The viewer's fitCanvasToViewport() keeps 150 px of
    ///   height for the top bar and button row: in this mode it is shown a taller window for the
    ///   duration of the call, so the screen uses that room. `make check` verifies what this relies on.
    static func layoutJS(deviceOnly: Bool) -> String {
        """
        (() => {
          const style = document.createElement('style');
          style.textContent = `
            #brand-logo, #brand { display: none !important; }
            html.pmd3-device-only #topbar,
            html.pmd3-device-only .tray,
            html.pmd3-device-only #bottom-row { display: none !important; }
            html.pmd3-device-only #stage-wrap { padding-top: 12px; padding-bottom: 12px; }
          `;
          document.documentElement.appendChild(style);

          let deviceOnly = \(deviceOnly);
          document.documentElement.classList.toggle('pmd3-device-only', deviceOnly);

          const VIEWER_RESERVED_H = 150, OWN_RESERVED_H = 24;
          const install = () => {
            const orig = window.fitCanvasToViewport;
            if (typeof orig !== 'function' || orig.__pmd3bar) return;
            const fit = function () {
              if (!deviceOnly) return orig();
              const own = Object.getOwnPropertyDescriptor(window, 'innerHeight');
              const h = window.innerHeight;
              Object.defineProperty(window, 'innerHeight',
                                    {get: () => h + VIEWER_RESERVED_H - OWN_RESERVED_H, configurable: true});
              try { orig(); } finally {
                if (own) Object.defineProperty(window, 'innerHeight', own); else delete window.innerHeight;
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
    /// The recording is video only (the viewer plays audio through its own private AudioContext).
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

      let recorder = null, chunks = [], mime = '';
      window.__pmd3bar = {
        startRecording() {
          const canvas = document.getElementById('c');
          if (!canvas || !canvas.captureStream) return 'Schermo non disponibile per la registrazione';
          if (typeof MediaRecorder === 'undefined') return 'Registrazione non supportata';
          mime = ['video/mp4;codecs=avc1', 'video/mp4', 'video/webm'].find(t => MediaRecorder.isTypeSupported(t)) || '';
          chunks = [];
          try {
            recorder = new MediaRecorder(canvas.captureStream(30), mime ? {mimeType: mime, videoBitsPerSecond: 8000000} : {});
          } catch (e) { return 'Registrazione non avviata: ' + e.message; }
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
