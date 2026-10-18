import SwiftUI
import UIKit
import AVFoundation

@main
struct LampaPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            Group {
                if router.showLampa {
                    LampaScreen()
                } else {
                    HomeView()
                }
            }
            .environmentObject(router)
            .onOpenURL { router.open($0) }
            .fullScreenCover(item: $router.request) { request in
                PlayerView(request: request)
            }
            .alert("Не получилось открыть ссылку", isPresented: $router.showParseError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(router.lastBadURL ?? "")
            }
            .alert("Lampa", isPresented: $router.showWebAlertFlag) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(router.webAlertText)
            }
        }
    }
}

final class Router: ObservableObject {
    @Published var request: PlaybackRequest?
    @Published var showParseError = false
    @Published private(set) var lastBadURL: String?
    /// Главный экран — встроенная Lampa (иначе — экран плеера с историей и настройками).
    @Published var showLampa = AppSettings.lampaEnabled && AppSettings.normalizedLampaURL(AppSettings.lampaURL) != nil
    /// Настройки плеера поверх встроенной Lampa.
    @Published var showSettings = false
    @Published var showWebAlertFlag = false
    @Published private(set) var webAlertText = ""

    func open(_ url: URL) {
        guard let parsed = LaunchParser.parse(url) else {
            fail(url.absoluteString)
            return
        }
        present(parsed)
    }

    func fail(_ text: String) {
        lastBadURL = text
        showParseError = true
    }

    func showWebAlert(_ text: String) {
        webAlertText = text
        showWebAlertFlag = true
    }

    func present(_ newRequest: PlaybackRequest) {
        // Плеер показывается с корня — сначала убираем шторку настроек, если она открыта.
        if showSettings {
            showSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.present(newRequest) }
            return
        }
        if request == nil {
            request = newRequest
            return
        }
        // Плеер уже открыт (Lampa прислала новую серию) — закрываем старый и открываем заново.
        request = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.request = newRequest
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        TorrServerManager.shared.startIfEnabled()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

enum Orientation {
    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    /// Разрешённые ориентации без принудительного поворота (крутится вместе с телефоном).
    static func lock(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene else { return }
        if #available(iOS 16.0, *) {
            refreshControllers(in: scene)
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    /// Кнопка «повернуть»: работает и при включённой блокировке поворота.
    /// После неё экран держит выбранную ориентацию, пока плеер открыт.
    static func toggle() {
        guard let scene else { return }
        let toPortrait = scene.interfaceOrientation.isLandscape
        let mask: UIInterfaceOrientationMask = toPortrait ? .portrait : .landscape
        AppDelegate.orientationMask = mask
        if #available(iOS 16.0, *) {
            refreshControllers(in: scene)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        } else {
            let target: UIInterfaceOrientation = toPortrait ? .portrait : .landscapeRight
            UIDevice.current.setValue(target.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    @available(iOS 16.0, *)
    private static func refreshControllers(in scene: UIWindowScene) {
        var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}

enum AudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
