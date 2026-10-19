import Foundation

/// Режим скриншотов для README. Включается только переменной окружения LP_SHOT,
/// которую ставит tools/screenshots.sh в симуляторе (CI → Screenshots). В обычном запуске ничего не делает.
enum Demo {
    static let scene = ProcessInfo.processInfo.environment["LP_SHOT"]

    /// Что показать в плеере после паузы.
    enum Action {
        case none
        case sheet(PlayerSheet)
        case lock
        case volume
        case seek
    }

    /// Сцены плеера: с какой секунды фильма начать и что показать.
    private static let playerScenes: [String: (start: Double, action: Action)] = [
        "player": (200, .none),
        "skip": (18, .none),
        "next": (690, .none),
        "tracks": (200, .sheet(.subtitles)),
        "playlist": (200, .sheet(.playlist)),
        "tuning": (200, .sheet(.tuning)),
        "tech": (200, .sheet(.tech)),
        "lock": (330, .lock),
        "volume": (330, .volume),
        "seek": (200, .seek),
        "portrait": (330, .none),
    ]

    static var playerScene: Bool { playerScenes[scene ?? ""] != nil }
    static var action: Action { playerScenes[scene ?? ""]?.action ?? .none }
    static var landscape: Bool { playerScene && scene != "portrait" }
    /// Отсчёт до следующей серии начинается с 10 — ставим паузу сразу, чтобы цифра была крупной.
    static var pauseDelay: Double { scene == "next" ? 1.5 : 8 }

    /// Фильм Blender «Tears of Steel» и субтитры к нему. Скрипт кладёт их в Documents/demo заранее,
    /// иначе — тестовый HLS (с технической надписью в кадре) и субтитры с сайта Blender.
    private static let localDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("demo")
    private static let remoteStream = "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel-multi-lang.ism/.m3u8"
    private static let subtitles = [
        ("ru", "Русские"), ("en", "English"), ("de", "Deutsch"),
        ("es", "Español"), ("fr-orig", "Français"), ("it", "Italiano"),
    ]

    private static func local(_ name: String) -> String? {
        let url = localDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    static func prepareDefaults() {
        guard scene != nil else { return }
        // Каждая сцена начинает с нуля: иначе плеер продолжит с позиции прошлой сцены.
        ResumeStore.clearAll()
        HistoryStore.clear()
        let defaults = UserDefaults.standard
        defaults.set("ru", forKey: AppSettings.languageKey)
        defaults.set(true, forKey: AppSettings.autoNextKey)
        defaults.set(AppSettings.SkipMode.button.rawValue, forKey: AppSettings.skipModeKey)
        defaults.set(scene == "settings-torr", forKey: AppSettings.torrServerEnabledKey)
    }

    static func start(router: Router) {
        switch scene {
        case let s? where s.hasPrefix("settings"):
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { router.showSettings = true }
            if s == "settings-torr" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { TorrServerManager.shared.selfTest() }
            }
        case "lampa-card":
            // Открываем первую карточку на главной Lampa (её обработчик — событие hover:enter).
            runInLampa(after: 15, "var c=document.querySelector('.card');if(c)$(c).trigger('hover:enter')")
        case "lampa-menu":
            // Меню Lampa с пунктом «Lampa Player» от плагина.
            runInLampa(after: 15, "var m=document.querySelector('.head__menu-icon');if(m){$(m).trigger('hover:enter');m.click()}")
        case let s? where playerScene:
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                router.present(request(startAt: playerScenes[s]!.start))
            }
        default:
            break
        }
    }

    private static func runInLampa(after delay: Double, _ js: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            LampaBridge.shared.webView?.evaluateJavaScript("(function(){try{\(js)}catch(e){}})()")
        }
    }

    private static func request(startAt: Double) -> PlaybackRequest {
        let stream = local("tos.mov") ?? remoteStream
        let subs = subtitles.map { code, label in
            SubtitleRef(url: local("TOS-\(code).srt")
                            ?? "https://download.blender.org/demo/movies/ToS/subtitles/TOS-\(code).srt",
                        label: label)
        }
        // Заставка в начале, реклама в середине, титры в конце — чтобы на полосе были видны метки.
        let segments = SkipSegments(ads: [[420, 445]], skips: [[0, 35], [680, 734]], referenceDuration: 0)
        let items = (1...3).map { n in
            PlayItem(url: stream, title: "Tears of Steel. Серия \(n)", position: n == 1 ? startAt : nil,
                     subs: subs, segments: segments)
        }
        return PlaybackRequest(items: items, startIndex: 0, source: "demo")
    }
}
