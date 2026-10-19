import Foundation

/// Режим скриншотов для README. Включается только переменной окружения LP_SHOT,
/// которую ставит tools/screenshots.sh в симуляторе (CI → Screenshots). В обычном запуске ничего не делает.
///
/// Сцены: lampa — встроенная Lampa; settings — настройки поверх неё;
/// player — плеер с контролами; tracks — выбор субтитров; next — отсчёт до следующей серии.
enum Demo {
    static let scene = ProcessInfo.processInfo.environment["LP_SHOT"]

    static var playerScene: Bool { ["player", "tracks", "next"].contains(scene ?? "") }

    /// Открытый фильм Blender «Tears of Steel»: HLS с двумя озвучками и субтитры на разных языках.
    private static let stream = "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel-multi-lang.ism/.m3u8"
    private static let subtitles = [
        ("ru", "Русские"), ("en", "English"), ("de", "Deutsch"),
        ("es", "Español"), ("fr-orig", "Français"), ("it", "Italiano"),
    ]

    static func prepareDefaults() {
        guard scene != nil else { return }
        // Каждая сцена начинает с нуля: иначе плеер продолжит с позиции прошлой сцены.
        ResumeStore.clearAll()
        HistoryStore.clear()
        let defaults = UserDefaults.standard
        defaults.set("ru", forKey: AppSettings.languageKey)
        defaults.set(true, forKey: AppSettings.autoNextKey)
        defaults.set(AppSettings.SkipMode.button.rawValue, forKey: AppSettings.skipModeKey)
    }

    static func start(router: Router) {
        switch scene {
        case "settings":
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { router.showSettings = true }
        case let s? where playerScene:
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                router.present(request(startAt: s == "next" ? 690 : 300))
            }
        default:
            break
        }
    }

    private static func request(startAt: Double) -> PlaybackRequest {
        let subs = subtitles.map {
            SubtitleRef(url: "https://download.blender.org/demo/movies/ToS/subtitles/TOS-\($0.0).srt", label: $0.1)
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
