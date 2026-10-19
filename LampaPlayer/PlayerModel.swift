import Foundation
import UIKit
import AVFoundation
import MPVKit

/// CAMetalLayer для vo=gpu-next, с обходом из демо MPVKit.
final class MetalLayer: CAMetalLayer {
    // MoltenVK иногда ставит drawableSize 1x1, чтобы дожать презентацию: мерцание и «застрявший» размер.
    // https://github.com/mpv-player/mpv/pull/13651
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// Куда mpv выводит картинку.
enum VideoOutput: String {
    /// AVSampleBufferDisplayLayer: кадры VideoToolbox идут на экран без копий, работает PiP и HDR (EDR).
    case avfoundation
    /// libplacebo через MoltenVK: точнее цвета Dolby Vision profile 5, но без PiP.
    case gpuNext

    static var current: VideoOutput {
        VideoOutput(rawValue: UserDefaults.standard.string(forKey: AppSettings.videoOutputKey) ?? "") ?? .avfoundation
    }
}

final class MPVVideoView: UIView {
    let output: VideoOutput
    let displayLayer = AVSampleBufferDisplayLayer()
    let metalLayer = MetalLayer()

    init(output: VideoOutput) {
        self.output = output
        super.init(frame: .zero)
        backgroundColor = .black
        switch output {
        case .avfoundation:
            displayLayer.videoGravity = .resizeAspect
            displayLayer.backgroundColor = UIColor.black.cgColor
            if #available(iOS 17.0, *), AppSettings.hdr {
                displayLayer.wantsExtendedDynamicRangeContent = true
            }
            layer.addSublayer(displayLayer)
        case .gpuNext:
            metalLayer.contentsScale = UIScreen.main.nativeScale
            metalLayer.framebufferOnly = true
            metalLayer.backgroundColor = UIColor.black.cgColor
            layer.addSublayer(metalLayer)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var renderLayer: CALayer { output == .avfoundation ? displayLayer : metalLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderLayer.frame = bounds
        CATransaction.commit()
    }

    func setFill(_ fill: Bool) {
        displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

/// Часто меняющееся время воспроизведения живёт отдельно: иначе весь экран с кнопками
/// перерисовывается дважды в секунду, и нажатия теряются.
struct PlayerStats: Equatable {
    /// «1080p», «4K».
    var quality: String?
    var hdr: String?
    /// «hevc 1920×960 (13,8 Мбит/с) HDR10 msk05»
    var videoLine: String?
    /// «Канал: 46,0 Мбит/с  Буфер: 59 с»
    var networkLine: String?
}

final class PlayerStatsStore: ObservableObject {
    @Published var value = PlayerStats()
}

final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var cacheEnd: Double = 0
    @Published var scrubTime: Double?
    /// Метки пропуска текущей серии — рисуются на полосе перемотки.
    @Published var segments: [SkipRange] = []
}

struct SkipRange: Hashable {
    enum Kind: Hashable { case intro, ad }
    let start: Double
    let end: Double
    let kind: Kind
}

/// Обёртка над libmpv + состояние для SwiftUI.
///
/// Потоки: @Published и всё состояние модели — только главный поток. К mpv обращаемся ТОЛЬКО на `queue`:
/// vo=avfoundation при создании вывода синхронно ходит в главный поток, и любой блокирующий вызов
/// libmpv из главного потока в этот момент вешает приложение намертво.
final class PlayerModel: ObservableObject {
    @Published private(set) var items: [PlayItem]
    @Published private(set) var index: Int
    @Published private(set) var paused = false
    @Published private(set) var loading = true
    @Published private(set) var buffering = false
    @Published private(set) var bufferingPercent: Int?
    @Published private(set) var speedText: String?
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subTracks: [MediaTrack] = []
    @Published private(set) var playbackSpeed: Double = AppSettings.playbackSpeed
    @Published private(set) var nextCountdown: Int?
    @Published private(set) var fill = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var finished = false
    @Published var controlsVisible = true
    @Published private(set) var toast: String?
    @Published private(set) var resumeOffer: Double?
    @Published private(set) var pipActive = false
    @Published private(set) var audioDelay: Double = 0
    @Published private(set) var subDelay: Double = 0
    @Published private(set) var subScale: Double = AppSettings.subScale
    @Published private(set) var activeSegment: SkipRange?

    let output: VideoOutput
    let videoView: MPVVideoView
    let clock = PlaybackClock()
    let thumbnails = ThumbnailProvider()
    /// Тех. строки и качество — отдельно, чтобы раз в секунду перерисовывалась только плашка, а не весь плеер.
    let statsStore = PlayerStatsStore()
    let successURL: String?
    /// Плеер свёрнут в картинку в картинке: полноэкранного экрана нет, а воспроизведение идёт.
    var collapsed = false
    /// Router следит за PiP: старт — свернуть плеер, стоп крестиком — закончить сессию.
    var onPiPActiveChanged: ((Bool) -> Void)?
    /// Кнопка «развернуть» в окне PiP.
    var onPiPRestore: ((@escaping (Bool) -> Void) -> Void)?
    private(set) var log: [String] = []

    var position: Double {
        get { clock.position }
        set { if clock.position != newValue { clock.position = newValue } }
    }
    private(set) var duration: Double {
        get { clock.duration }
        set { if clock.duration != newValue { clock.duration = newValue } }
    }
    private var cacheEnd: Double {
        get { clock.cacheEnd }
        set { if abs(clock.cacheEnd - newValue) > 0.5 || newValue == 0 { clock.cacheEnd = newValue } }
    }
    var scrubTime: Double? { clock.scrubTime }

    var current: PlayItem { items[index] }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index + 1 < items.count }
    var pipAvailable: Bool { pip != nil }

    private let mpv: OpaquePointer
    private let queue = DispatchQueue(label: "lampaplayer.mpv", qos: .userInitiated)
    private let hwdecValue: String

    // Главный поток.
    private var alive = true
    private var started = false
    private var timer: Timer?
    private var tickInFlight = false
    private var ticks = 0
    private var hideWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var pip: PiPController?
    private var statusObservation: NSKeyValueObservation?
    private var remote: RemoteControls?
    private var wasPlayingBeforeInterruption = false
    private var decoderResets = 0
    private var skippedSegments: Set<SkipRange> = []
    private var countdownRemaining: Double?
    private var countdownLastTick: Date?
    private var countdownCancelled = false

    // Только очередь mpv.
    private var destroyed = false
    private var pendingSubs: [SubtitleRef] = []

    /// Выбор озвучки/субтитров переносим на следующие серии.
    private struct TrackChoice { let title: String?; let lang: String?; let ordinal: Int; let off: Bool }
    private var audioChoice: TrackChoice?
    private var subChoice: TrackChoice?
    /// Качество, выбранное вручную, — на все серии сессии. nil — лучшее из доступных.
    @Published private(set) var qualityChoice: String?

    /// Какое качество сейчас играет (если балансер дал несколько).
    var currentQuality: QualityLink? {
        guard let list = current.qualities, !list.isEmpty else { return nil }
        return list.first(where: { $0.label == qualityChoice }) ?? list[0]
    }

    init(request: PlaybackRequest) {
        items = request.items
        index = min(max(request.startIndex, 0), max(request.items.count - 1, 0))
        successURL = request.successURL
        output = VideoOutput.current
        videoView = MPVVideoView(output: output)
        hwdecValue = AppSettings.hwdec ? "videotoolbox" : "no"
        mpv = mpv_create()
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Настройка mpv

    /// Опции до mpv_initialize: видеовывода ещё нет, поэтому из главного потока это безопасно.
    private func configure() {
        let target: CALayer = videoView.renderLayer
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(target).toOpaque()))
        check(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid), "wid")

        var options: [(String, String)] = []
        switch output {
        case .avfoundation:
            options += [
                ("vo", "avfoundation"),
                // Субтитры и OSD впекаются в кадр — тогда они видны и в PiP. Ставить сразу после vo.
                ("avfoundation-composite-osd", "yes"),
            ]
        case .gpuNext:
            options += [
                ("vo", "gpu-next"),
                ("gpu-api", "vulkan"),
                ("gpu-context", "moltenvk"),
            ]
        }

        let languages = LanguagePrefs.mpvList()
        let subtitleMode = AppSettings.subtitleMode
        let fontsDir = Bundle.main.resourceURL?.appendingPathComponent("Fonts").path ?? ""
        options += [
            ("hwdec", hwdecValue),
            ("hwdec-codecs", "all"),
            ("hwdec-software-fallback", "yes"),
            ("ao", "audiounit"),
            // Без этого ao_audiounit ставит сессии MixWithOthers — тогда iOS не делает нас «Сейчас играет»,
            // и кнопки наушников уходят в Музыку.
            ("audio-exclusive", "yes"),
            ("video-rotate", "no"),
            ("idle", "yes"),
            ("keep-open", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osd-level", "0"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
            // Сеть и кэш: TorrServer отдаёт первые байты долго, пока качает начало файла.
            ("cache", "yes"),
            ("demuxer-max-bytes", "200MiB"),
            ("demuxer-max-back-bytes", "64MiB"),
            ("demuxer-readahead-secs", "30"),
            ("network-timeout", "90"),
            // Онлайн-CDN (okcdn и т.п.) сверяют UA с тем, что был у браузера при получении ссылки.
            // UA встроенной Lampa (если открывали её) — точное совпадение с браузером, который получил ссылку.
            ("user-agent", AppSettings.webUserAgent ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
            // Автовыбор озвучки и субтитров по языку.
            ("alang", languages),
            // Субтитры — по режиму из настроек; что mpv всё же выберет, поправит enforceSubtitleMode().
            ("slang", subtitleMode == .off ? "" : languages),
            ("subs-with-matching-audio", "forced"),
            ("subs-fallback", subtitleMode == .auto ? "default" : "no"),
            ("subs-fallback-forced", subtitleMode == .off ? "no" : "yes"),
            ("demuxer-mkv-subtitle-preroll", "yes"),
            ("sub-fonts-dir", fontsDir),
            ("sub-font", "Roboto"),
            ("sub-border-size", "2.5"),
            ("sub-shadow-offset", "1"),
            ("sub-ass-force-margins", "yes"),
            ("sub-scale", String(format: "%.2f", subScale)),
            ("speed", String(format: "%.2f", playbackSpeed)),
        ]
        for (name, value) in options {
            check(mpv_set_option_string(mpv, name, value), "\(name)=\(value)")
        }

        check(mpv_request_log_messages(mpv, "info"), "log")
        check(mpv_initialize(mpv), "initialize")

        mpv_observe_property(mpv, 0, "track-list", MPV_FORMAT_NONE)
        mpv_observe_property(mpv, 0, "aid", MPV_FORMAT_NONE)
        mpv_observe_property(mpv, 0, "sid", MPV_FORMAT_NONE)

        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            Unmanaged<PlayerModel>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Жизненный цикл

    func start() {
        guard alive, !started else { return }
        started = true

        if output == .avfoundation {
            // iOS выгружает декодер VideoToolbox в фоне/при нехватке ресурсов — слой падает в .failed.
            statusObservation = videoView.displayLayer.observe(\.status, options: [.new]) { [weak self] layer, _ in
                guard layer.status == .failed else { return }
                DispatchQueue.main.async { self?.recoverDecoder() }
            }
            pip = PiPController(layer: videoView.displayLayer, delegate: self)
            pip?.setAutoStart(AppSettings.autoPiP)
        }

        remote = RemoteControls(model: self)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        play(index: index)
        scheduleHide()
        if playbackSpeed != 1 {
            // Скорость запомнилась с прошлого раза — напоминаем, чтобы не удивляться.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.showToast("Скорость \(Self.formatSpeed(self.playbackSpeed))")
            }
        }
    }

    func shutdown() {
        guard alive else { return }
        saveProgress()
        alive = false
        timer?.invalidate()
        timer = nil
        hideWork?.cancel()
        toastWork?.cancel()
        statusObservation?.invalidate()
        statusObservation = nil
        // Окно PiP этой сессии закрываем явно (например, открыли другое видео, пока это шло в PiP).
        if pip?.isActive == true { pip?.stop() }
        onPiPActiveChanged = nil
        onPiPRestore = nil
        pip?.invalidate()
        pip = nil
        remote?.invalidate()
        remote = nil
        // mpv держит слой без retain и шлёт ему кадры, пока не остановится. Держим self (и слой)
        // до конца terminate_destroy, а отпускаем в главном потоке — слой из дерева нельзя рушить в чужом.
        queue.async { [self] in
            destroyed = true
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
            DispatchQueue.main.async { withExtendedLifetime(self) {} }
        }
    }

    @objc private func didEnterBackground() {
        guard alive else { return }
        saveProgress()
        if output == .gpuNext {
            // Без этого после возврата бывает чёрный экран (так делает и демо MPVKit).
            setFlag("pause", true)
            paused = true
            set("vid", "no")
            return
        }
        // Автоматический PiP включается чуть позже ухода в фон — даём ему время, иначе ставим на паузу.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.alive, !self.pipActive,
                  UIApplication.shared.applicationState == .background, !self.paused else { return }
            self.setFlag("pause", true)
            self.paused = true
        }
    }

    @objc private func willEnterForeground() {
        guard alive else { return }
        if output == .gpuNext { set("vid", "auto") }
    }

    private func recoverDecoder() {
        guard alive, decoderResets < 3 else { return }
        decoderResets += 1
        let last = decoderResets >= 3
        let hwdec = hwdecValue
        appendLog("Слой вывода упал, перезапускаю декодер (\(decoderResets)/3)")
        onQueue { h in
            Self.qSet(h, "hwdec", "no")
            // На последней попытке остаёмся на программном декодере, чтобы не зациклиться.
            if !last { Self.qSet(h, "hwdec", hwdec) }
        }
    }

    // MARK: - Воспроизведение

    func play(index newIndex: Int, at explicitStart: Double? = nil) {
        guard alive, items.indices.contains(newIndex) else { return }
        if started && newIndex != index { saveProgress() }
        if newIndex != index { httpsRetried = false }
        index = newIndex
        errorMessage = nil
        finished = false
        loading = true
        buffering = false
        position = 0
        duration = 0
        cacheEnd = 0
        audioTracks = []
        subTracks = []
        resumeOffer = nil
        decoderResets = 0
        activeSegment = nil
        clock.segments = []
        countdownCancelled = false
        clearNextCountdown()

        let item = items[newIndex]
        thumbnails.load(item.thumbnails)
        var startAt = explicitStart ?? 0
        if explicitStart == nil {
            // Lampa не узнаёт наш прогресс, так что своя позиция свежее; её нет — берём позицию от Lampa.
            if let saved = ResumeStore.position(for: item.resumeKey), saved > 15 {
                startAt = saved
            } else if let fromLampa = item.position, fromLampa > 15 {
                startAt = fromLampa
            }
            if startAt > 0 { resumeOffer = startAt }
        }

        let start = startAt > 1 ? String(format: "%.1f", startAt) : "none"
        // Ссылки на встроенный TorrServer — мимо прокси для Lampa, сразу на сам сервер.
        // Балансер дал ссылки на качества — по умолчанию лучшее (его url не всегда максимальный).
        var url = Self.preferHTTPS(TorrServerManager.directURL(currentQuality?.url ?? item.url))
        if forceHTTPS { url = Self.httpsVersion(of: url) ?? url }
        forceHTTPS = false
        loadedURL = url
        let headers = Self.browserHeaders(for: url)
        onQueue { [weak self] h in
            self?.pendingSubs = item.externalSubtitles
            Self.qSet(h, "start", start)
            Self.qSet(h, "referrer", headers.referrer)
            Self.qSet(h, "http-header-fields", headers.fields)
            Self.qCommand(h, ["loadfile", url, "replace"])
        }
    }

    /// Что открывали последним (для повтора по https).
    private var loadedURL = ""
    private var forceHTTPS = false
    private var httpsRetried = false

    /// Ссылки MODS (api.lampa.stream) — всегда по https. По http iOS может пустить их через «Частный узел iCloud»
    /// с другим IP, чем у Lampa, которая получала ссылку, — подпись не сходится, сервер отвечает 403.
    static func preferHTTPS(_ url: String) -> String {
        guard url.hasPrefix("http://"), let host = URLComponents(string: url)?.host?.lowercased(),
              host == "lampa.stream" || host.hasSuffix(".lampa.stream") else { return url }
        return httpsVersion(of: url) ?? url
    }

    static func httpsVersion(of url: String) -> String? {
        guard url.hasPrefix("http://") else { return nil }
        return "https://" + url.dropFirst("http://".count)
    }

    private static func isLocal(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return true }
        return host == "127.0.0.1" || host == "localhost"
    }

    /// Referer и Origin как у браузера с Lampa: часть CDN без них отвечает 403.
    /// TorrServer (локальный) — без них: в него зашит бан Referer/Origin зеркал Lampa.
    private static func browserHeaders(for url: String) -> (referrer: String, fields: String) {
        guard !isLocal(url), let lampa = AppSettings.normalizedLampaURL(AppSettings.lampaURL),
              let scheme = lampa.scheme, let host = lampa.host else { return ("", "") }
        let origin = "\(scheme)://\(host)" + (lampa.port.map { ":\($0)" } ?? "")
        return (origin + "/", "Origin: " + origin)
    }

    /// Другое качество — с той же позиции. Выбор держится на следующие серии.
    func selectQuality(_ link: QualityLink) {
        guard alive, link != currentQuality else { return }
        qualityChoice = link.label
        showToast("Качество: \(link.title)")
        play(index: index, at: position > 1 ? position : nil)
    }

    func retry() {
        let at = position > 1 ? position : nil
        play(index: index, at: at)
    }

    func next() { if hasNext { play(index: index + 1) } }
    func previous() { if hasPrevious { play(index: index - 1) } }

    func togglePause() {
        setPaused(!paused)
        poke()
    }

    private func setPaused(_ value: Bool) {
        guard alive else { return }
        setFlag("pause", value)
        paused = value
        pip?.update(position: position, rate: value ? 0 : playbackSpeed)
        updateNowPlaying(force: true)
    }

    // MARK: - Пульт (наушники, экран блокировки)

    func logRemote(_ command: String) {
        appendLog("Пульт: \(command)")
    }

    func remotePlay(_ playing: Bool) {
        guard alive, playing == paused else { return }
        setPaused(!playing)
        showToast(playing ? "Воспроизведение" : "Пауза")
    }

    func interruptionBegan() {
        guard alive else { return }
        wasPlayingBeforeInterruption = !paused
        if !paused { setPaused(true) }
    }

    func interruptionEnded(resume: Bool) {
        guard alive else { return }
        if resume && wasPlayingBeforeInterruption {
            try? AVAudioSession.sharedInstance().setActive(true)
            setPaused(false)
        }
        wasPlayingBeforeInterruption = false
    }

    private func updateNowPlaying(force: Bool = false) {
        let subtitle = items.count > 1 ? "Серия \(index + 1) из \(items.count)" : nil
        remote?.update(title: current.displayTitle, subtitle: subtitle, position: position,
                       duration: duration, rate: paused || loading ? 0 : playbackSpeed, force: force)
    }

    func seek(to seconds: Double) {
        guard alive else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        command(["seek", String(format: "%.2f", target), "absolute"])
        position = target
        poke()
    }

    func seek(by delta: Double) {
        guard alive else { return }
        command(["seek", String(format: "%.0f", delta), "relative"])
        position = max(0, position + delta)
        showToast(delta > 0 ? "+\(Int(delta)) с" : "−\(Int(-delta)) с")
    }

    func restartFromBeginning() {
        resumeOffer = nil
        seek(to: 0)
    }

    func setSpeed(_ value: Double) {
        guard alive else { return }
        setDouble("speed", value)
        playbackSpeed = value
        AppSettings.playbackSpeed = value
        showToast(value == 1 ? "Обычная скорость" : "Скорость \(Self.formatSpeed(value))")
    }

    func toggleFill() {
        setFill(!fill)
    }

    func setFill(_ value: Bool) {
        guard alive, value != fill else { return }
        if output == .avfoundation {
            videoView.setFill(value)
        } else {
            setDouble("panscan", value ? 1 : 0)
        }
        fill = value
        showToast(value ? "Заполнить экран" : "Вписать в экран")
    }

    func setAudioDelay(_ seconds: Double) {
        guard alive else { return }
        let value = (seconds * 10).rounded() / 10
        setDouble("audio-delay", value)
        audioDelay = value
    }

    func setSubDelay(_ seconds: Double) {
        guard alive else { return }
        let value = (seconds * 10).rounded() / 10
        setDouble("sub-delay", value)
        subDelay = value
    }

    func setSubScale(_ scale: Double) {
        guard alive else { return }
        let value = min(max(scale, 0.5), 2.5)
        setDouble("sub-scale", value)
        subScale = value
        AppSettings.subScale = value
    }

    func selectAudio(_ track: MediaTrack) {
        guard alive else { return }
        set("aid", "\(track.id)")
        audioChoice = choice(for: track, in: audioTracks)
        showToast(track.label)
    }

    func selectSubtitle(_ track: MediaTrack?) {
        guard alive else { return }
        if let track {
            set("sid", "\(track.id)")
            subChoice = choice(for: track, in: subTracks)
            showToast("Субтитры: \(track.label)")
        } else {
            set("sid", "no")
            subChoice = TrackChoice(title: nil, lang: nil, ordinal: 0, off: true)
            showToast("Субтитры выключены")
        }
    }

    // MARK: - PiP

    func togglePiP() {
        guard let pip else {
            showToast("PiP работает только с видеовыводом AVFoundation")
            return
        }
        if pip.isActive {
            pip.stop()
        } else if pip.isPossible {
            pip.start()
        } else {
            showToast("PiP пока недоступен — дождитесь картинки")
        }
    }

    // MARK: - Интерфейс

    func poke() {
        if !controlsVisible { controlsVisible = true }
        scheduleHide()
    }

    func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.paused, self.scrubTime == nil, self.errorMessage == nil else { return }
            self.controlsVisible = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func showToast(_ text: String) {
        toastWork?.cancel()
        toast = text
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    static func formatSpeed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%g×", value)
    }

    // MARK: - Опрос состояния

    private struct Snapshot {
        var position: Double?
        var duration: Double?
        var cacheTime: Double?
        var paused: Bool?
        var buffering: Bool?
        var percent: Int?
        var speed: Int64?
        var video: VideoStats?
    }

    /// Сырые данные для тех. строк и кнопки качества (читаются на очереди mpv, пока видны контролы).
    private struct VideoStats {
        var codec: String?
        var width: Int?
        var height: Int?
        var bitrate: Double?
        var gamma: String?
        var cacheSpeed: Int64?
        var cacheDuration: Double?
    }

    private func tick() {
        guard alive, !tickInFlight else { return }
        tickInFlight = true
        let wantStats = loading || buffering
        let wantVideo = controlsVisible
        onQueue { [weak self] h in
            var s = Snapshot()
            s.position = Self.qDouble(h, "time-pos")
            s.duration = Self.qDouble(h, "duration")
            s.cacheTime = Self.qDouble(h, "demuxer-cache-time")
            s.paused = Self.qFlag(h, "pause")
            s.buffering = Self.qFlag(h, "paused-for-cache")
            if wantStats || wantVideo {
                s.speed = Self.qInt(h, "cache-speed")
            }
            if wantStats {
                s.percent = Self.qInt(h, "cache-buffering-state").map { Int($0) }
            }
            if wantVideo {
                s.video = VideoStats(
                    codec: Self.qString(h, "video-format"),
                    width: Self.qInt(h, "video-params/w").map { Int($0) },
                    height: Self.qInt(h, "video-params/h").map { Int($0) },
                    bitrate: Self.qDouble(h, "video-bitrate"),
                    gamma: Self.qString(h, "video-params/gamma"),
                    cacheSpeed: s.speed,
                    cacheDuration: Self.qDouble(h, "demuxer-cache-duration"))
            }
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    private func applyVideoStats(_ v: VideoStats) {
        var stats = PlayerStats()
        // Качество — по ширине: кино 1920×800 — это всё равно «1080p».
        if let w = v.width, let h = v.height, w > 0, h > 0 {
            switch w {
            case 3200...: stats.quality = "4K"
            case 2300..<3200: stats.quality = "1440p"
            case 1800..<2300: stats.quality = "1080p"
            case 1200..<1800: stats.quality = "720p"
            default: stats.quality = "\(h)p"
            }
        }
        switch v.gamma {
        case "pq": stats.hdr = "HDR10"
        case "hlg": stats.hdr = "HLG"
        default: break
        }
        var video: [String] = []
        if let codec = v.codec { video.append(codec) }
        if let w = v.width, let h = v.height, w > 0, h > 0 { video.append("\(w)×\(h)") }
        if let rate = v.bitrate, rate > 0 { video.append("(\(Self.formatMbit(rate)))") }
        if let hdr = stats.hdr { video.append(hdr) }
        if let host = sourceLabel { video.append(host) }
        stats.videoLine = video.isEmpty ? nil : video.joined(separator: " ")
        var net: [String] = []
        if let speed = v.cacheSpeed, speed > 0 { net.append("Канал: " + Self.formatMbit(Double(speed) * 8)) }
        if let buffer = v.cacheDuration { net.append(String(format: "Буфер: %.0f с", buffer)) }
        stats.networkLine = net.isEmpty ? nil : net.joined(separator: "  ")
        if stats != statsStore.value { statsStore.value = stats }
    }

    /// «13,8 Мбит/с» — по-русски, с запятой.
    private static func formatMbit(_ bitsPerSecond: Double) -> String {
        let text = bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Мбит/с", bitsPerSecond / 1_000_000)
            : String(format: "%.0f кбит/с", bitsPerSecond / 1000)
        return text.replacingOccurrences(of: ".", with: ",")
    }

    /// Откуда идёт видео, коротко: «TorrServer» или первая часть адреса CDN («msk05» из msk05.cdn.net).
    private var sourceLabel: String? {
        guard let host = URLComponents(string: current.url)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host == "127.0.0.1" || host == "localhost" { return "TorrServer" }
        let parts = host.split(separator: ".")
        if parts.count >= 3, parts.allSatisfy({ !$0.allSatisfy(\.isNumber) }) { return String(parts[0]) }
        return host
    }

    private func apply(_ s: Snapshot) {
        tickInFlight = false
        guard alive else { return }
        if scrubTime == nil, let p = s.position { position = p }
        if let d = s.duration, d > 0, d != duration {
            duration = d
            if current.segments != nil { refreshSegments() }
        }
        cacheEnd = s.cacheTime ?? 0
        if let v = s.video { applyVideoStats(v) }
        if let p = s.paused, p != paused { paused = p }
        if let b = s.buffering, b != buffering { buffering = b }
        if loading || buffering {
            if s.percent != bufferingPercent { bufferingPercent = s.percent }
            let text = s.speed.flatMap { $0 > 0 ? Self.formatBytesPerSecond($0) : nil }
            if text != speedText { speedText = text }
        }
        pip?.update(position: position, rate: paused ? 0 : playbackSpeed)
        updateNowPlaying()
        updateActiveSegment()
        updateNextCountdown()

        ticks += 1
        if ticks % 10 == 0 { saveProgress() }
    }

    private static func formatBytesPerSecond(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f МБ/с", mb) : String(format: "%.0f КБ/с", Double(bytes) / 1024)
    }

    private func saveProgress() {
        guard alive, !loading, duration > 0, position > 5 else { return }
        ResumeStore.store(position, duration: duration, for: current.resumeKey)
        if let hash = current.lampaHash { LampaProgressStore.record(hash: hash, time: position, duration: duration) }
    }

    // MARK: - События mpv (очередь mpv)

    private func drainEvents() {
        queue.async { [weak self] in
            guard let self, !self.destroyed else { return }
            while true {
                guard let event = mpv_wait_event(self.mpv, 0)?.pointee else { break }
                if event.event_id == MPV_EVENT_NONE { break }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            Self.qSet(mpv, "start", "none")
            // Внешние субтитры: с заголовком и языком, иначе mpv называет дорожку длинным URL.
            for sub in pendingSubs {
                let title = sub.label.isEmpty ? "Из Lampa" : sub.label
                Self.qCommand(mpv, ["sub-add", sub.url, "auto", title, Self.languageCode(fromLabel: title)])
            }
            pendingSubs = []
            let duration = Self.qDouble(mpv, "duration")
            let tracks = readTracks()
            DispatchQueue.main.async { self.fileLoaded(duration: duration, tracks: tracks) }

        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            // reason в разных версиях заголовка — то enum, то int; оба 4 байта.
            let reason = withUnsafeBytes(of: end.reason) { $0.load(as: Int32.self) }
            let error = end.error
            DispatchQueue.main.async { self.fileEnded(reason: reason, error: error) }

        case MPV_EVENT_PROPERTY_CHANGE:
            let tracks = readTracks()
            DispatchQueue.main.async { self.publishTracks(tracks) }

        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let line = "[\(String(cString: message.prefix))] \(String(cString: message.text))"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.appendLog(line) }

        default:
            break
        }
    }

    private func readTracks() -> (audio: [MediaTrack], subs: [MediaTrack]) {
        guard let count = Self.qInt(mpv, "track-list/count") else { return ([], []) }
        var audio: [MediaTrack] = []
        var subs: [MediaTrack] = []
        for i in 0..<Int(count) {
            let p = "track-list/\(i)/"
            guard let type = Self.qString(mpv, p + "type"), let id = Self.qInt(mpv, p + "id") else { continue }
            guard type == "audio" || type == "sub" else { continue }
            let track = MediaTrack(
                id: Int(id),
                title: Self.qString(mpv, p + "title"),
                lang: Self.qString(mpv, p + "lang"),
                codec: Self.qString(mpv, p + "codec"),
                channels: type == "audio" ? Self.qInt(mpv, p + "demux-channel-count").map { Int($0) } : nil,
                external: Self.qFlag(mpv, p + "external") ?? false,
                forced: Self.qFlag(mpv, p + "forced") ?? false,
                selected: Self.qFlag(mpv, p + "selected") ?? false
            )
            if type == "audio" { audio.append(track) } else { subs.append(track) }
        }
        return (audio, subs)
    }

    // MARK: - События mpv (главный поток)

    private func appendLog(_ line: String) {
        let stamp = Self.logTime.string(from: Date())
        log.append("\(stamp) \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func publishTracks(_ tracks: (audio: [MediaTrack], subs: [MediaTrack])) {
        guard alive else { return }
        if tracks.audio != audioTracks { audioTracks = tracks.audio }
        if tracks.subs != subTracks { subTracks = tracks.subs }
    }

    private func fileLoaded(duration loaded: Double?, tracks: (audio: [MediaTrack], subs: [MediaTrack])) {
        guard alive else { return }
        loading = false
        bufferingPercent = nil
        speedText = nil
        if let loaded, loaded > 0 { duration = loaded }
        publishTracks(tracks)
        applyRememberedTracks()
        autoSelectExternalSubtitles()
        enforceSubtitleMode()
        refreshSegments()
        updateNowPlaying(force: true)
        HistoryStore.record(items: items, index: index)
        if resumeOffer != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.resumeOffer = nil }
        }
    }

    private func fileEnded(reason: Int32, error: Int32) {
        guard alive else { return }
        switch reason {
        case 0: // EOF
            // Оборванный поток mpv тоже считает концом файла. Если до конца далеко — это обрыв, а не финал.
            if duration > 0, position < duration - 30 {
                loading = false
                errorMessage = "Поток оборвался на \(Self.formatTime(position)). Нажмите «Повторить», чтобы продолжить."
                return
            }
            if duration > 0 {
                ResumeStore.store(duration, duration: duration, for: current.resumeKey)
                if let hash = current.lampaHash { LampaProgressStore.record(hash: hash, time: duration, duration: duration) }
            }
            if hasNext {
                play(index: index + 1)
            } else {
                finished = true
            }
        case 4: // ERROR
            // http-ссылка не открылась — один раз пробуем её же по https (см. preferHTTPS).
            if !httpsRetried, !Self.isLocal(loadedURL), Self.httpsVersion(of: loadedURL) != nil {
                httpsRetried = true
                forceHTTPS = true
                appendLog("Не открылось по http — пробую https")
                play(index: index, at: position > 1 ? position : nil)
                return
            }
            loading = false
            errorMessage = String(cString: mpv_error_string(error))
            controlsVisible = true
        default:
            break // STOP — это наш же loadfile replace
        }
    }

    // MARK: - Тех. данные

    struct TechSection: Identifiable {
        let title: String
        let rows: [(String, String)]
        var id: String { title }
    }

    /// Снимок технических данных для экрана «Тех. данные». Свойства читаются на очереди mpv.
    func techInfo(_ completion: @escaping ([TechSection]) -> Void) {
        guard alive else { return completion([]) }
        let output = self.output
        let item = current
        let played = loadedURL.isEmpty ? item.url : loadedURL
        let quality = currentQuality.map { link in
            "\(link.title) из \((item.qualities ?? []).map(\.title).joined(separator: ", "))"
        }
        onQueue { h in
            func v(_ name: String) -> String? {
                guard let s = Self.qString(h, name), !s.isEmpty else { return nil }
                return s
            }
            func row(_ title: String, _ value: String?) -> (String, String)? {
                value.map { (title, $0) }
            }
            func bytes(_ name: String, perSecond: Bool = false) -> String? {
                guard let n = Self.qInt(h, name) else { return nil }
                let mb = Double(n) / 1_048_576
                let text = mb >= 1 ? String(format: "%.1f МБ", mb) : String(format: "%.0f КБ", Double(n) / 1024)
                return perSecond ? text + "/с" : text
            }
            func kbps(_ name: String) -> String? {
                guard let n = Self.qDouble(h, name), n > 0 else { return nil }
                return n >= 1_000_000 ? String(format: "%.1f Мбит/с", n / 1_000_000) : String(format: "%.0f кбит/с", n / 1000)
            }
            let width = v("video-params/w"), height = v("video-params/h")
            let sections = [
                TechSection(title: "Источник", rows: [
                    row("Название", item.displayTitle),
                    row("Ссылка", played),
                    row("Субтитры от Lampa", item.sub),
                    row("Перевод из Lampa", item.voice),
                    row("Качество", quality),
                    row("Контейнер", v("file-format")),
                    row("Размер", bytes("file-size")),
                    row("Длительность", v("duration").flatMap(Double.init).map { Self.formatTime($0) }),
                ].compactMap { $0 }),
                TechSection(title: "Сеть и кэш", rows: [
                    row("Скорость загрузки", bytes("cache-speed", perSecond: true)),
                    row("Буфер вперёд", v("demuxer-cache-duration").flatMap(Double.init).map { String(format: "%.1f с", $0) }),
                    row("Ждёт данные", v("paused-for-cache")),
                    row("Заполнение буфера", v("cache-buffering-state").map { $0 + "%" }),
                    row("Сетевой поток", v("demuxer-via-network")),
                ].compactMap { $0 }),
                TechSection(title: "Видео", rows: [
                    row("Кодек", v("video-codec")),
                    row("Разрешение", width.flatMap { w in height.map { "\(w)×\($0)" } }),
                    row("Частота кадров", v("container-fps")),
                    row("Битрейт", kbps("video-bitrate")),
                    row("Пиксельный формат", v("video-params/pixelformat")),
                    row("Аппаратный декодер", v("hwdec-current")),
                    row("Видеовывод", v("current-vo") ?? output.rawValue),
                    row("Цветовые координаты", v("video-params/primaries")),
                    row("Передаточная функция", v("video-params/gamma")),
                    row("Пиковая яркость", v("video-params/sig-peak")),
                    row("Пропущено кадров", v("frame-drop-count")),
                    row("Пропущено декодером", v("decoder-frame-drop-count")),
                    row("Рассинхрон A/V", v("avsync").flatMap(Double.init).map { String(format: "%.3f с", $0) }),
                ].compactMap { $0 }),
                TechSection(title: "Аудио", rows: [
                    row("Кодек", v("audio-codec-name")),
                    row("Дорожка", v("current-tracks/audio/title") ?? v("current-tracks/audio/lang")),
                    row("Каналы", v("audio-params/channel-count")),
                    row("Частота", v("audio-params/samplerate").map { $0 + " Гц" }),
                    row("Битрейт", kbps("audio-bitrate")),
                    row("Аудиовывод", v("current-ao")),
                    row("Задержка звука", v("audio-delay")),
                ].compactMap { $0 }),
                TechSection(title: "Субтитры", rows: [
                    row("Дорожка", v("current-tracks/sub/title") ?? v("current-tracks/sub/lang")),
                    row("Кодек", v("current-tracks/sub/codec")),
                    row("Задержка", v("sub-delay")),
                    row("Масштаб", v("sub-scale")),
                ].compactMap { $0 }),
                TechSection(title: "Сборка", rows: [
                    row("mpv", v("mpv-version")),
                    row("FFmpeg", v("ffmpeg-version")),
                ].compactMap { $0 }),
            ].filter { !$0.rows.isEmpty }
            DispatchQueue.main.async { completion(sections) }
        }
    }

    private static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Дорожки

    private func choice(for track: MediaTrack, in list: [MediaTrack]) -> TrackChoice {
        TrackChoice(title: track.title, lang: track.lang, ordinal: list.firstIndex(of: track) ?? 0, off: false)
    }

    private func match(_ choice: TrackChoice, in list: [MediaTrack]) -> MediaTrack? {
        if let title = choice.title, !title.isEmpty,
           let byTitle = list.first(where: { $0.title == title }) {
            return byTitle
        }
        if choice.title == nil || choice.title?.isEmpty == true, list.indices.contains(choice.ordinal) {
            let candidate = list[choice.ordinal]
            if choice.lang == nil || candidate.lang == choice.lang { return candidate }
        }
        return nil
    }

    private func applyRememberedTracks() {
        if let audioChoice, let track = match(audioChoice, in: audioTracks), !track.selected {
            set("aid", "\(track.id)")
        }
        if let subChoice {
            if subChoice.off {
                set("sid", "no")
            } else if let track = match(subChoice, in: subTracks), !track.selected {
                set("sid", "\(track.id)")
            }
        }
    }

    /// Внешние субтитры mpv не выбирает сам (добавлены после автовыбора). Правило как у встроенных:
    /// озвучка на нашем языке — только форсированные, иначе полные на нашем языке.
    private func autoSelectExternalSubtitles() {
        let mode = AppSettings.subtitleMode
        guard mode != .off, subChoice == nil, !subTracks.contains(where: { $0.selected }) else { return }
        let external = subTracks.filter { $0.external }
        guard !external.isEmpty else { return }

        let preferred = LanguagePrefs.mpvList().split(separator: ",").map { String($0) }
        func isPreferred(_ lang: String?) -> Bool {
            guard let lang = lang?.lowercased() else { return false }
            return preferred.contains(lang)
        }

        let audioLang = audioTracks.first(where: { $0.selected })?.lang
        let audioIsOurs = isPreferred(audioLang)
        let ours = external.filter { isPreferred($0.lang) }
        let pick = audioIsOurs || mode == .forced
            ? ours.first(where: Self.isForced)
            : (ours.first(where: { !Self.isForced($0) }) ?? ours.first)
        if let pick { set("sid", "\(pick.id)") }
    }

    private static func isForced(_ track: MediaTrack) -> Bool {
        track.forced || (track.title?.lowercased().contains("forced") ?? false)
            || (track.title?.lowercased().contains("форс") ?? false)
    }

    /// Режим из настроек сильнее автовыбора mpv (он включает дорожки с флагом «по умолчанию» и полные
    /// субтитры, когда у озвучки нет метки языка). Ручной выбор в этой сессии сильнее режима.
    private func enforceSubtitleMode() {
        guard subChoice == nil, let selected = subTracks.first(where: { $0.selected }) else { return }
        switch AppSettings.subtitleMode {
        case .auto:
            return
        case .forced:
            if !Self.isForced(selected) { set("sid", "no") }
        case .off:
            set("sid", "no")
        }
    }

    /// «RUS - [FORCED]», «ENG», «ukr / Повні» → трёхбуквенный код языка для mpv.
    static func languageCode(fromLabel label: String) -> String {
        let lower = label.lowercased()
        let table: [(String, [String])] = [
            ("rus", ["rus", "рус", "russian"]), ("ukr", ["ukr", "укр", "ukrainian"]),
            ("eng", ["eng", "англ", "english"]), ("bel", ["bel", "бел"]), ("kaz", ["kaz", "каз"]),
            ("ger", ["ger", "deu", "нем", "german"]), ("fre", ["fre", "fra", "фра", "french"]),
            ("spa", ["spa", "исп", "spanish"]), ("ita", ["ita", "ита", "italian"]), ("jpn", ["jpn", "япон", "japanese"]),
            ("kor", ["kor", "кор", "korean"]), ("chi", ["chi", "zho", "кит", "chinese"]), ("heb", ["heb", "иврит"]),
        ]
        for (code, keys) in table where keys.contains(where: { lower.hasPrefix($0) || lower.contains(" \($0)") }) {
            return code
        }
        return ""
    }

    // MARK: - Пропуск заставок и рекламы

    /// Сегменты под фактическую длительность файла. Метки размечены по эталону duration_ms;
    /// если наш файл длиннее, титры в конце сдвигаем к концу файла (как делает сама Lampa).
    private func mappedSegments() -> [SkipRange] {
        guard let segments = current.segments else { return [] }
        let reference = segments.referenceDuration
        let shift = (reference > 0 && duration > 0 && abs(duration - reference) > 2) ? duration - reference : 0
        func map(_ pair: [Double], kind: SkipRange.Kind) -> SkipRange? {
            guard pair.count == 2 else { return nil }
            var start = pair[0], end = pair[1]
            if shift > 0, reference > 0, start > reference * 0.55 { start += shift; end += shift }
            if duration > 0 { end = min(end, duration) }
            return end - start > 1 ? SkipRange(start: start, end: end, kind: kind) : nil
        }
        return (segments.skips.compactMap { map($0, kind: .intro) } + segments.ads.compactMap { map($0, kind: .ad) })
            .sorted { $0.start < $1.start }
    }

    private func refreshSegments() {
        let mapped = mappedSegments()
        if mapped != clock.segments { clock.segments = mapped }
        skippedSegments.removeAll()
    }

    /// Вызывается из тика: показать кнопку «Пропустить» или пропустить автоматически.
    private func updateActiveSegment() {
        let mode = AppSettings.skipMode
        guard mode != .off, !loading, scrubTime == nil else {
            if activeSegment != nil { activeSegment = nil }
            return
        }
        var segment = clock.segments.first { position >= $0.start && position < $0.end - 1 }
        // Финальные титры при следующей серии — дело отсчёта «Следующая серия через N», а не «Пропустить».
        if let current = segment, current == creditsSegment, hasNext, AppSettings.autoNext { segment = nil }
        if mode == .auto, let segment, !skippedSegments.contains(segment) {
            skippedSegments.insert(segment)
            seek(to: segment.end)
            showToast(segment.kind == .ad ? "Реклама пропущена" : "Заставка пропущена")
            if activeSegment != nil { activeSegment = nil }
            return
        }
        if segment != activeSegment { activeSegment = segment }
    }

    func skipActiveSegment() {
        guard let segment = activeSegment else { return }
        skippedSegments.insert(segment)
        activeSegment = nil
        seek(to: segment.end)
    }

    // MARK: - Следующая серия

    /// Метка финальных титров: заставочная метка во второй половине серии.
    private var creditsSegment: SkipRange? {
        guard duration > 0 else { return nil }
        return clock.segments.first { $0.kind == .intro && $0.start > duration * 0.55 }
    }

    var nextTitle: String? { hasNext ? items[index + 1].displayTitle : nil }

    /// Вызывается из тика. Старт — на метке титров, без меток — за 20 с до конца. На паузе замирает.
    private func updateNextCountdown() {
        guard AppSettings.autoNext, hasNext, !loading, duration > 60, !countdownCancelled,
              scrubTime == nil, errorMessage == nil else {
            clearNextCountdown()
            return
        }
        let trigger = creditsSegment?.start ?? max(duration - 20, 0)
        guard position >= trigger else {
            clearNextCountdown()
            return
        }
        let now = Date()
        if countdownRemaining == nil {
            countdownRemaining = 10
        } else if !paused, let last = countdownLastTick {
            countdownRemaining! -= now.timeIntervalSince(last)
        }
        countdownLastTick = now
        if countdownRemaining! <= 0 {
            clearNextCountdown()
            next()
            return
        }
        let shown = Int(countdownRemaining!.rounded(.up))
        if nextCountdown != shown { nextCountdown = shown }
    }

    func playNextNow() {
        clearNextCountdown()
        next()
    }

    func cancelNextCountdown() {
        countdownCancelled = true
        clearNextCountdown()
    }

    private func clearNextCountdown() {
        countdownRemaining = nil
        countdownLastTick = nil
        if nextCountdown != nil { nextCountdown = nil }
    }

    // MARK: - Доступ к libmpv

    /// Единственный путь к mpv после инициализации.
    private func onQueue(_ work: @escaping (OpaquePointer) -> Void) {
        queue.async { [self] in
            guard !destroyed else { return }
            work(mpv)
        }
    }

    private func command(_ args: [String]) {
        guard alive else { return }
        onQueue { h in Self.qCommand(h, args) }
    }

    private func set(_ name: String, _ value: String) {
        guard alive else { return }
        onQueue { h in Self.qSet(h, name, value) }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard alive else { return }
        onQueue { h in
            var flag: Int32 = value ? 1 : 0
            mpv_set_property(h, name, MPV_FORMAT_FLAG, &flag)
        }
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard alive else { return }
        onQueue { h in
            var number = value
            mpv_set_property(h, name, MPV_FORMAT_DOUBLE, &number)
        }
    }

    private func check(_ status: Int32, _ what: String) {
        guard status < 0 else { return }
        let line = "mpv \(what): \(String(cString: mpv_error_string(status)))"
        if Thread.isMainThread { appendLog(line) } else { DispatchQueue.main.async { self.appendLog(line) } }
    }

    // Только на очереди mpv.

    private static func qCommand(_ h: OpaquePointer, _ args: [String]) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for pointer in cargs {
                if let pointer { free(UnsafeMutablePointer(mutating: pointer)) }
            }
        }
        mpv_command(h, &cargs)
    }

    private static func qSet(_ h: OpaquePointer, _ name: String, _ value: String) {
        mpv_set_property_string(h, name, value)
    }

    private static func qDouble(_ h: OpaquePointer, _ name: String) -> Double? {
        var value = Double()
        return mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    private static func qInt(_ h: OpaquePointer, _ name: String) -> Int64? {
        var value = Int64()
        return mpv_get_property(h, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private static func qFlag(_ h: OpaquePointer, _ name: String) -> Bool? {
        var value = Int32()
        return mpv_get_property(h, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    private static func qString(_ h: OpaquePointer, _ name: String) -> String? {
        guard let cString = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension PlayerModel: PiPControllerDelegate {
    func pipDidChangeActive(_ active: Bool) {
        pipActive = active
        onPiPActiveChanged?(active)
    }

    func pipSetPlaying(_ playing: Bool) {
        setPaused(!playing)
    }

    func pipSkip(by seconds: Double) {
        guard alive else { return }
        command(["seek", String(format: "%.0f", seconds), "relative"])
        position = max(0, position + seconds)
    }

    var pipIsPlaying: Bool { !paused }
    var pipDuration: Double { duration }

    func pipRestoreUserInterface(_ completion: @escaping (Bool) -> Void) {
        if let onPiPRestore {
            onPiPRestore(completion)
        } else {
            completion(true)
        }
    }
}
