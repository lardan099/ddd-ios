import SwiftUI
import UIKit
import WebKit

/// Связь встроенной Lampa с приложением: ставит отметки просмотра напрямую через JS.
final class LampaBridge: ObservableObject {
    static let shared = LampaBridge()

    /// Плагин добавил пункт «Lampa Player» в меню — запасную кнопку настроек можно спрятать.
    @Published var menuReady = false
    @Published var loadError: String?
    weak var webView: WKWebView?

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidClose),
                                               name: .lampaPlayerDidClose, object: nil)
    }

    @objc private func playerDidClose() {
        // Даём Lampa секунду вернуться на экран, потом ставим отметки.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.pushProgress() }
    }

    /// Пока идёт наш плеер (и в PiP), Lampa не должна ничего играть: её заставка «Природа»/Aerial
    /// через N минут без касаний запускает <video> и отбирает у mpv звук и картинку.
    func setPlayerActive(_ active: Bool) {
        guard let webView else { return }
        let script = active
            ? "(function(){try{var s=window.Lampa&&Lampa.Screensaver;if(!s)return;window.__lampaPlayerSS=s.enabled;if(s.isWorked())s.stopSlideshow();s.disable()}catch(e){}})()"
            : "(function(){try{var s=window.Lampa&&Lampa.Screensaver;if(s&&window.__lampaPlayerSS!==false)s.enable()}catch(e){}})()"
        webView.evaluateJavaScript(script, completionHandler: nil)
        if active { webView.pauseAllMediaPlayback(completionHandler: nil) }
        webView.setAllMediaPlaybackSuspended(active, completionHandler: nil)
    }

    /// Отдаёт накопленные позиции в Lampa.Timeline (через функцию плагина) и забывает их при успехе.
    func pushProgress() {
        guard let webView else { return }
        let json = LampaProgressStore.pendingJSON()
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]], !list.isEmpty,
              let text = String(data: json, encoding: .utf8) else { return }
        let hashes = list.compactMap { $0["h"] as? String }
        let script = "(function(l){try{return window.__lampaPlayerApplyProgress?window.__lampaPlayerApplyProgress(l):-1}catch(e){return -2}})(\(text))"
        webView.evaluateJavaScript(script) { result, _ in
            if let applied = result as? Int, applied > 0 {
                LampaProgressStore.acknowledge(hashes)
            } else if let applied = result as? Double, applied > 0 {
                LampaProgressStore.acknowledge(hashes)
            }
        }
    }
}

extension Notification.Name {
    static let lampaPlayerDidClose = Notification.Name("lampaPlayerDidClose")
}

struct LampaWebView: UIViewRepresentable {
    let url: URL
    let router: Router

    func makeCoordinator() -> Coordinator { Coordinator(router: router) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // localStorage и вход в аккаунт Lampa переживают перезапуск
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        // Хвост как у Safari: часть сайтов и CDN не любит «голый» WebView.
        configuration.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"

        let controller = configuration.userContentController
        controller.add(WeakScriptHandler(context.coordinator), name: "lampaPlayer")
        controller.addUserScript(WKUserScript(source: "window.__lampa_player_embedded = true;",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let plugin = Self.pluginSource {
            controller.addUserScript(WKUserScript(source: plugin, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        LampaBridge.shared.webView = webView
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Адрес Lampa поменяли в настройках — перезагружаем.
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    /// Плагин лежит в бандле (тот же файл, что опубликован на GitHub Pages).
    static let pluginSource: String? = {
        guard let url = Bundle.main.url(forResource: "lampa-player", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let router: Router
        var loadedURL: URL?

        init(router: Router) { self.router = router }

        // Ссылки «внешнего плеера» — сразу в наш плеер; чужие схемы — системе; остальное грузим сами.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
                decisionHandler(.allow)
                return
            }
            switch scheme {
            case "lampaplayer", "infuse", "senplayer":
                decisionHandler(.cancel)
                router.open(url)
            case "http", "https", "about", "blob", "data", "file":
                decisionHandler(.allow)
            default:
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            LampaBridge.shared.loadError = nil
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                if let ua = result as? String, !ua.isEmpty { AppSettings.webUserAgent = ua }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            LampaBridge.shared.loadError = error.localizedDescription
        }

        // target=_blank и window.open (трейлеры, ссылки на сайты) — в Safari.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if ["lampaplayer", "infuse", "senplayer"].contains(url.scheme?.lowercased() ?? "") {
                    router.open(url)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            router.showWebAlert(message)
            completionHandler()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "settings":
                router.showSettings = true
            case "menu":
                LampaBridge.shared.menuReady = true
            case "ready":
                if let ua = body["ua"] as? String, !ua.isEmpty { AppSettings.webUserAgent = ua }
                LampaBridge.shared.pushProgress()
            default:
                break
            }
        }
    }
}

/// WKUserContentController держит обработчик сильно — разрываем цикл.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Главный экран во встроенном режиме: Lampa на весь экран + запасная кнопка настроек.
struct LampaScreen: View {
    @EnvironmentObject private var router: Router
    @ObservedObject private var bridge = LampaBridge.shared
    @AppStorage(AppSettings.lampaURLKey) private var lampaURL = AppSettings.defaultLampaURL

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.ignoresSafeArea()
            if let url = AppSettings.normalizedLampaURL(lampaURL) {
                LampaWebView(url: url, router: router)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            if let error = bridge.loadError {
                VStack(spacing: 12) {
                    Text("Lampa не открылась").font(.headline)
                    Text(error).font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary)
                    Button("Настройки") { router.showSettings = true }.buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
            if !bridge.menuReady {
                // Пока плагин не добавил пункт «Lampa Player» в меню Lampa.
                Button { router.showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $router.showSettings) {
            HomeView()
                .environmentObject(router)
        }
    }
}
