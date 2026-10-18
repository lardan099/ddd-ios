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
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var cacheEnd: Double = 0
    @Published var scrubTime: Double?
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
    @Published private(set) var playbackSpeed: Double = 1
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

    let output: VideoOutput
    let videoView: MPVVideoView
    let clock = PlaybackClock()
    let successURL: String?
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

    // Только очередь mpv.
    private var destroyed = false
    private var pendingSub: String?

    /// Выбор озвучки/субтитров переносим на следующие серии.
    private struct TrackChoice { let title: String?; let lang: String?; let ordinal: Int; let off: Bool }
    private var audioChoice: TrackChoice?
    private var subChoice: TrackChoice?

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
        let fontsDir = Bundle.main.resourceURL?.appendingPathComponent("Fonts").path ?? ""
        options += [
            ("hwdec", hwdecValue),
            ("hwdec-codecs", "all"),
            ("hwdec-software-fallback", "yes"),
            ("ao", "audiounit"),
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
            ("user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
            // Автовыбор озвучки и субтитров по языку.
            ("alang", languages),
            ("slang", languages),
            ("subs-with-matching-audio", "forced"),
            ("subs-fallback", "default"),
            ("subs-fallback-forced", "yes"),
            ("demuxer-mkv-subtitle-preroll", "yes"),
            ("sub-fonts-dir", fontsDir),
            ("sub-font", "Roboto"),
            ("sub-border-size", "2.5"),
            ("sub-shadow-offset", "1"),
            ("sub-ass-force-margins", "yes"),
            ("sub-scale", String(format: "%.2f", subScale)),
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

        let item = items[newIndex]
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
        let url = TorrServerManager.directURL(item.url)
        onQueue { [weak self] h in
            self?.pendingSub = item.sub
            Self.qSet(h, "start", start)
            Self.qCommand(h, ["loadfile", url, "replace"])
        }
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
    }

    private func tick() {
        guard alive, !tickInFlight else { return }
        tickInFlight = true
        let wantStats = loading || buffering
        onQueue { [weak self] h in
            var s = Snapshot()
            s.position = Self.qDouble(h, "time-pos")
            s.duration = Self.qDouble(h, "duration")
            s.cacheTime = Self.qDouble(h, "demuxer-cache-time")
            s.paused = Self.qFlag(h, "pause")
            s.buffering = Self.qFlag(h, "paused-for-cache")
            if wantStats {
                s.percent = Self.qInt(h, "cache-buffering-state").map { Int($0) }
                s.speed = Self.qInt(h, "cache-speed")
            }
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    private func apply(_ s: Snapshot) {
        tickInFlight = false
        guard alive else { return }
        if scrubTime == nil, let p = s.position { position = p }
        if let d = s.duration, d > 0 { duration = d }
        cacheEnd = s.cacheTime ?? 0
        if let p = s.paused, p != paused { paused = p }
        if let b = s.buffering, b != buffering { buffering = b }
        if loading || buffering {
            if s.percent != bufferingPercent { bufferingPercent = s.percent }
            let text = s.speed.flatMap { $0 > 0 ? Self.formatBytesPerSecond($0) : nil }
            if text != speedText { speedText = text }
        }
        pip?.update(position: position, rate: paused ? 0 : playbackSpeed)
        updateNowPlaying()

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
            if let sub = pendingSub {
                // Без заголовка mpv называет дорожку длинным URL.
                Self.qCommand(mpv, ["sub-add", sub, "auto", "Из Lampa"])
            }
            pendingSub = nil
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
            if duration > 0 { ResumeStore.store(duration, duration: duration, for: current.resumeKey) }
            if hasNext {
                play(index: index + 1)
            } else {
                finished = true
            }
        case 4: // ERROR
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
                    row("Ссылка", item.url),
                    row("Субтитры от Lampa", item.sub),
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
        completion(true)
    }
}
