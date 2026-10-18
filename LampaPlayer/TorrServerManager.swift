import Foundation
import UIKit
import AVFoundation
import TorrServerKit

/// Встроенный TorrServer (TorrServerKit из релизов YouROK/TorrServer, gomobile).
/// Слушает 127.0.0.1:8090 — этот адрес указывается в Lampa как адрес TorrServer.
final class TorrServerManager: ObservableObject {
    static let shared = TorrServerManager()
    static let port = 8090
    static var address: String { "http://127.0.0.1:\(port)" }

    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?
    @Published private(set) var log: [String] = []

    /// Плеер открыт: у него своя аудиосессия, и звук фильма сам держит приложение в фоне.
    var playerActive = false

    private let queue = DispatchQueue(label: "lampaplayer.torrserver", qos: .userInitiated)
    private let keepAlive = BackgroundKeepAlive()

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("TorrServer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// Вызывается при запуске приложения: поднимает сервер, если он включён в настройках.
    func startIfEnabled() {
        if AppSettings.torrServerEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AppSettings.torrServerEnabledKey)
        enabled ? start() : stop()
    }

    func start() {
        guard !busy else { return }
        busy = true
        lastError = nil
        let dir = dataDirectory.path
        note("Запуск на порту \(Self.port), данные: \(dir)")
        queue.async { [weak self] in
            let error = TorrserverkitStartServer(Self.port, dir)
            let ok = error.isEmpty || TorrserverkitIsRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.running = ok
                self.lastError = error.isEmpty ? nil : error
                self.note(ok ? "Запущен: \(Self.address)" : "Ошибка запуска: \(error)")
            }
        }
    }

    func stop() {
        guard !busy else { return }
        busy = true
        note("Остановка")
        keepAlive.stop()
        queue.async { [weak self] in
            let error = TorrserverkitStopServer()
            let stillRunning = TorrserverkitIsRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.running = stillRunning
                self.lastError = error.isEmpty ? nil : error
                self.note(error.isEmpty ? "Остановлен" : "Ошибка остановки: \(error)")
            }
        }
    }

    func refreshStatus() {
        queue.async { [weak self] in
            let isRunning = TorrserverkitIsRunning()
            DispatchQueue.main.async { self?.running = isRunning }
        }
    }

    /// Путь к логу самого TorrServer (его пишет Go-часть).
    var serverLogURL: URL { dataDirectory.appendingPathComponent("torrserver.log") }

    func serverLogTail(maxBytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: serverLogURL) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func note(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("\(stamp) \(text)")
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }

    // MARK: - Фон

    // Пока Lampa открыта в Safari, наше приложение в фоне. Без звука iOS заморозит его через несколько
    // секунд, и TorrServer перестанет отвечать. Тихий звук держит процесс живым (режим audio в UIBackgroundModes).
    @objc private func willResignActive() {
        guard running, AppSettings.torrServerKeepAlive, !playerActive else { return }
        keepAlive.start()
        note("Фон: держу сервер живым тихим звуком")
    }

    @objc private func didBecomeActive() {
        if keepAlive.isRunning {
            keepAlive.stop()
            note("Вернулись из фона")
        }
        refreshStatus()
    }
}

/// Бесконечно проигрывает тишину. Сессия mixWithOthers — не глушит музыку и другие приложения.
final class BackgroundKeepAlive {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() {
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // Плеер сам переводит сессию в .playback/.moviePlayback, когда открыт; здесь только фон без плеера.
        if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity // нули = тишина
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        do {
            try engine.start()
        } catch {
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
