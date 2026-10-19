import SwiftUI
import UIKit
import AVFoundation

@main
struct LampaPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if router.showLampa {
                    LampaScreen()
                } else {
                    HomeView()
                }
                // Плеер свёрнут в картинку в картинке: видеослой живёт здесь, невидимо, пока идёт PiP.
                if let session = router.session, !router.playerVisible {
                    MPVVideoContainer(view: session.videoView)
                        .frame(width: 2, height: 2)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .environmentObject(router)
            .onAppear { Demo.start(router: router) }
            .onOpenURL { router.open($0) }
            .fullScreenCover(isPresented: $router.playerVisible) {
                if let session = router.session {
                    PlayerView(model: session)
                        .environmentObject(router)
                }
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
    /// Текущая сессия плеера. Живёт отдельно от полноэкранного экрана — переживает сворачивание в PiP.
    @Published private(set) var session: PlayerModel?
    /// Полноэкранный плеер показан.
    @Published var playerVisible = false
    @Published var showParseError = false
    @Published private(set) var lastBadURL: String?
    /// Главный экран — встроенная Lampa (иначе — экран плеера с историей и настройками).
    @Published var showLampa = AppSettings.lampaEnabled && AppSettings.normalizedLampaURL(AppSettings.lampaURL) != nil
    /// Настройки плеера поверх встроенной Lampa.
    @Published var showSettings = false
    @Published var showWebAlertFlag = false
    @Published private(set) var webAlertText = ""

    private var restoringFromPiP = false

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
        guard let old = session else {
            startSession(newRequest)
            return
        }
        // Уже что-то играет (открыт плеер или свёрнут в PiP) — заканчиваем и открываем новое.
        let wasVisible = playerVisible
        old.collapsed = false
        if wasVisible {
            playerVisible = false // onDisappear плеера сам закончит сессию
        } else {
            endSession(old)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasVisible ? 0.6 : 0.2)) { [weak self] in
            self?.startSession(newRequest)
        }
    }

    private func startSession(_ request: PlaybackRequest) {
        let model = PlayerModel(request: request)
        model.onPiPActiveChanged = { [weak self, weak model] active in
            guard let self, let model, self.session === model else { return }
            if active {
                self.collapse(model)
            } else {
                // Крестик в окне PiP, пока плеер свёрнут, — конец просмотра. «Развернуть» сюда не попадает.
                if model.collapsed && !self.restoringFromPiP { self.endSession(model) }
                self.restoringFromPiP = false
            }
        }
        model.onPiPRestore = { [weak self, weak model] completion in
            guard let self, let model, self.session === model else { return completion(false) }
            self.restoringFromPiP = true
            model.collapsed = false
            self.playerVisible = true
            // Даём полноэкранному плееру появиться, чтобы PiP «влетел» обратно в него.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion(true) }
        }
        session = model
        playerVisible = true
        LampaBridge.shared.setPlayerActive(true)
    }

    /// PiP включился — убираем полноэкранный плеер, под ним Lampa. Видео идёт в окошке.
    private func collapse(_ model: PlayerModel) {
        guard playerVisible else { return }
        model.collapsed = true
        playerVisible = false
    }

    /// Конец просмотра: останавливаем mpv, отпускаем звук, ставим отметки в Lampa.
    func endSession(_ model: PlayerModel) {
        guard session === model else {
            model.shutdown()
            return
        }
        session = nil
        model.collapsed = false
        model.shutdown()
        AudioSession.deactivate()
        TorrServerManager.shared.playerActive = false
        LampaBridge.shared.setPlayerActive(false)
        NotificationCenter.default.post(name: .lampaPlayerDidClose, object: nil)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Demo.prepareDefaults()
        TorrServerManager.shared.startIfEnabled()
        NetBridge.shared.start()
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
