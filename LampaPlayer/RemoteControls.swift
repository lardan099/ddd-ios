import Foundation
import MediaPlayer
import UIKit
import AVFoundation

/// Пульт iOS: кнопки наушников, экран блокировки, Пункт управления, «Сейчас играет».
/// Пока плеер открыт, приложение — владелец «Сейчас играет», поэтому «плей» на наушниках
/// управляет фильмом, а не запускает Музыку.
///
/// Наушники: одно нажатие — пауза/плей, двойное (или свайп вперёд) — следующая серия,
/// тройное (свайп назад) — предыдущая. Если серия одна, вместо переключения — перемотка на ±30 с.
final class RemoteControls {
    private weak var model: PlayerModel?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var lastInfoKey = ""

    init(model: PlayerModel) {
        self.model = model
        UIApplication.shared.beginReceivingRemoteControlEvents()
        register()
        observeAudioSession()
    }

    private func register() {
        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { m, _ in m.remotePlay(true); return .success }
        add(center.pauseCommand) { m, _ in m.remotePlay(false); return .success }
        add(center.togglePlayPauseCommand) { m, _ in m.togglePause(); return .success }

        add(center.nextTrackCommand) { m, _ in
            if m.items.count > 1 {
                guard m.hasNext else { return .noSuchContent }
                m.next()
            } else {
                m.seek(by: 30)
            }
            return .success
        }
        add(center.previousTrackCommand) { m, _ in
            if m.items.count > 1 {
                guard m.hasPrevious else { return .noSuchContent }
                m.previous()
            } else {
                m.seek(by: -30)
            }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { m, event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            m.seek(by: interval)
            return .success
        }
        add(center.skipBackwardCommand) { m, event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            m.seek(by: -interval)
            return .success
        }

        // Зажатие кнопки на некоторых наушниках: перематываем рывком при начале зажатия.
        add(center.seekForwardCommand) { m, event in
            if (event as? MPSeekCommandEvent)?.type == .beginSeeking { m.seek(by: 30) }
            return .success
        }
        add(center.seekBackwardCommand) { m, event in
            if (event as? MPSeekCommandEvent)?.type == .beginSeeking { m.seek(by: -30) }
            return .success
        }

        // Ползунок на экране блокировки и в Пункте управления.
        add(center.changePlaybackPositionCommand) { m, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            m.seek(to: event.positionTime)
            return .success
        }
    }

    private func add(_ command: MPRemoteCommand,
                     _ handler: @escaping (PlayerModel, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            guard let model = self?.model else { return .noActionableNowPlayingItem }
            return handler(model, event)
        }
        targets.append((command, target))
    }

    /// Обновляет «Сейчас играет». Позицию iOS сама продолжает по rate, поэтому часто дёргать не нужно.
    func update(title: String, subtitle: String?, position: Double, duration: Double, rate: Double, force: Bool = false) {
        // Пересылаем при смене трека/паузы/скорости и раз в ~5 с — иначе система копит рассинхрон.
        let key = "\(title)|\(Int(duration))|\(rate)|\(Int(position / 5))"
        guard force || key != lastInfoKey else { return }
        lastInfoKey = key

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        info[MPMediaItemPropertyAlbumTitle] = "Lampa Player"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func invalidate() {
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Наушники вынули, звонок

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(routeChanged(_:)),
                           name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(interrupted(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
    }

    /// Вынули наушники / отключились AirPods — пауза, как в любом плеере, а не звук из динамика.
    @objc private func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in
            self?.model?.remotePlay(false)
        }
    }

    /// Звонок или будильник: пауза; после — продолжаем, если система разрешает.
    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let model = self?.model else { return }
            switch type {
            case .began:
                model.interruptionBegan()
            case .ended:
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                model.interruptionEnded(resume: shouldResume)
            @unknown default:
                break
            }
        }
    }
}
