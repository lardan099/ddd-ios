import Foundation
import UIKit
import Libmpv

/// CAMetalLayer с обходами из демо MPVKit.
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

final class MPVVideoView: UIView {
    let metalLayer = MetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Обёртка над libmpv + состояние для SwiftUI.
/// Все @Published меняются только в главном потоке; события mpv читаются на своей очереди.
final class PlayerModel: ObservableObject {
    @Published private(set) var items: [PlayItem]
    @Published private(set) var index: Int
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var cacheEnd: Double = 0
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
    @Published var scrubTime: Double?
    @Published var controlsVisible = true
    @Published private(set) var toast: String?
    @Published private(set) var resumeOffer: Double?

    let videoView = MPVVideoView()
    let successURL: String?
    private(set) var log: [String] = []

    private let mpv: OpaquePointer
    private let queue = DispatchQueue(label: "lampaplayer.mpv", qos: .userInitiated)
    /// Только главный поток. После shutdown к mpv из главного потока не обращаемся.
    private var alive = true
    /// Только очередь mpv.
    private var destroyed = false
    private var started = false
    private var timer: Timer?
    private var ticks = 0
    private var hideWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?

    /// Выбор озвучки/субтитров переносим на следующие серии.
    private struct TrackChoice { let title: String?; let lang: String?; let ordinal: Int; let off: Bool }
    private var audioChoice: TrackChoice?
    private var subChoice: TrackChoice?

    var current: PlayItem { items[index] }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index + 1 < items.count }

    init(request: PlaybackRequest) {
        items = request.items
        index = min(max(request.startIndex, 0), max(request.items.count - 1, 0))
        successURL = request.successURL
        mpv = mpv_create()
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Настройка mpv

    private func configure() {
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(videoView.metalLayer).toOpaque()))
        check(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid), "wid")

        let languages = LanguagePrefs.mpvList()
        let fontsDir = Bundle.main.resourceURL?.appendingPathComponent("Fonts").path ?? ""
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", AppSettings.hwdec ? "videotoolbox" : "no"),
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
        ]
        for (name, value) in options {
            check(mpv_set_option_string(mpv, name, value), "\(name)=\(value)")
        }

        check(mpv_request_log_messages(mpv, "warn"), "log")
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
        // Держим self (и слой) живыми, пока mpv не остановит все свои потоки.
        queue.async { [self] in
            destroyed = true
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }

    @objc private func didEnterBackground() {
        guard alive else { return }
        saveProgress()
        setFlag("pause", true)
        // Без этого после возврата бывает чёрный экран (так делает и демо MPVKit).
        setString("vid", "no")
    }

    @objc private func willEnterForeground() {
        guard alive else { return }
        setString("vid", "auto")
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

        setString("start", startAt > 1 ? String(format: "%.1f", startAt) : "none")
        command(["loadfile", item.url, "replace"])
    }

    func retry() {
        let at = position > 1 ? position : nil
        play(index: index, at: at)
    }

    func next() { if hasNext { play(index: index + 1) } }
    func previous() { if hasPrevious { play(index: index - 1) } }

    func togglePause() {
        guard alive else { return }
        let newValue = !(getFlag("pause") ?? false)
        setFlag("pause", newValue)
        paused = newValue
        poke()
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

    func dismissResumeOffer() { resumeOffer = nil }

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
        setDouble("panscan", value ? 1 : 0)
        fill = value
        showToast(value ? "Заполнить экран" : "Вписать в экран")
    }

    func selectAudio(_ track: MediaTrack) {
        guard alive else { return }
        setString("aid", "\(track.id)")
        audioChoice = choice(for: track, in: audioTracks)
        showToast(track.label)
    }

    func selectSubtitle(_ track: MediaTrack?) {
        guard alive else { return }
        if let track {
            setString("sid", "\(track.id)")
            subChoice = choice(for: track, in: subTracks)
            showToast("Субтитры: \(track.label)")
        } else {
            setString("sid", "no")
            subChoice = TrackChoice(title: nil, lang: nil, ordinal: 0, off: true)
            showToast("Субтитры выключены")
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

    private func showToast(_ text: String) {
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

    private func tick() {
        guard alive else { return }
        if scrubTime == nil, let p = getDouble("time-pos") { position = p }
        if let d = getDouble("duration"), d > 0, d != duration { duration = d }
        cacheEnd = getDouble("demuxer-cache-time") ?? 0

        let isPaused = getFlag("pause") ?? false
        if isPaused != paused { paused = isPaused }
        let isBuffering = getFlag("paused-for-cache") ?? false
        if isBuffering != buffering { buffering = isBuffering }

        if loading || buffering {
            let percent = getInt("cache-buffering-state").map { Int($0) }
            if percent != bufferingPercent { bufferingPercent = percent }
            let text = getInt("cache-speed").flatMap { $0 > 0 ? Self.formatBytesPerSecond($0) : nil }
            if text != speedText { speedText = text }
        }

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

    // MARK: - События mpv

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
            DispatchQueue.main.async { self.fileLoaded() }

        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            // reason в разных версиях заголовка — то enum, то int; оба 4 байта.
            let reason = withUnsafeBytes(of: end.reason) { $0.load(as: Int32.self) }
            let error = end.error
            DispatchQueue.main.async { self.fileEnded(reason: reason, error: error) }

        case MPV_EVENT_PROPERTY_CHANGE:
            DispatchQueue.main.async { self.refreshTracks() }

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

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }

    private func fileLoaded() {
        guard alive else { return }
        loading = false
        bufferingPercent = nil
        speedText = nil
        setString("start", "none")
        if let sub = current.sub {
            command(["sub-add", sub, "auto"])
        }
        if let d = getDouble("duration"), d > 0 { duration = d }
        refreshTracks()
        applyRememberedTracks()
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

    // MARK: - Дорожки

    private func refreshTracks() {
        guard alive, let count = getInt("track-list/count") else { return }
        var audio: [MediaTrack] = []
        var subs: [MediaTrack] = []
        for i in 0..<Int(count) {
            let p = "track-list/\(i)/"
            guard let type = getString(p + "type"), let id = getInt(p + "id") else { continue }
            guard type == "audio" || type == "sub" else { continue }
            let track = MediaTrack(
                id: Int(id),
                title: getString(p + "title"),
                lang: getString(p + "lang"),
                codec: getString(p + "codec"),
                channels: type == "audio" ? getInt(p + "demux-channel-count").map { Int($0) } : nil,
                external: getFlag(p + "external") ?? false,
                forced: getFlag(p + "forced") ?? false,
                selected: getFlag(p + "selected") ?? false
            )
            if type == "audio" { audio.append(track) } else { subs.append(track) }
        }
        if audio != audioTracks { audioTracks = audio }
        if subs != subTracks { subTracks = subs }
    }

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
            setString("aid", "\(track.id)")
        }
        if let subChoice {
            if subChoice.off {
                setString("sid", "no")
            } else if let track = match(subChoice, in: subTracks), !track.selected {
                setString("sid", "\(track.id)")
            }
        }
    }

    // MARK: - Обёртки libmpv

    private func check(_ status: Int32, _ what: String) {
        if status < 0 {
            appendLog("mpv \(what): \(String(cString: mpv_error_string(status)))")
        }
    }

    private func command(_ args: [String]) {
        guard alive else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for pointer in cargs {
                if let pointer { free(UnsafeMutablePointer(mutating: pointer)) }
            }
        }
        check(mpv_command(mpv, &cargs), args.first ?? "command")
    }

    private func getDouble(_ name: String) -> Double? {
        guard alive else { return nil }
        var value = Double()
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    private func getInt(_ name: String) -> Int64? {
        guard alive else { return nil }
        var value = Int64()
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private func getFlag(_ name: String) -> Bool? {
        guard alive else { return nil }
        var value = Int32()
        return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    private func getString(_ name: String) -> String? {
        guard alive, let cString = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    private func setString(_ name: String, _ value: String) {
        guard alive else { return }
        check(mpv_set_property_string(mpv, name, value), "\(name)=\(value)")
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard alive else { return }
        var flag: Int32 = value ? 1 : 0
        check(mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &flag), name)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard alive else { return }
        var number = value
        check(mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &number), name)
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
