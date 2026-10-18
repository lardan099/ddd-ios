import SwiftUI
import UIKit
import AVFoundation

@main
struct LampaPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            HomeView()
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
        }
    }
}

final class Router: ObservableObject {
    @Published var request: PlaybackRequest?
    @Published var showParseError = false
    @Published private(set) var lastBadURL: String?

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

    func present(_ newRequest: PlaybackRequest) {
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
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

enum Orientation {
    static func lock(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ??
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        if #available(iOS 16.0, *) {
            var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            if mask != .all {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            }
        } else if mask == .landscape {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
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
