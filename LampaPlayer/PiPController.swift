import AVKit
import AVFoundation

protocol PiPControllerDelegate: AnyObject {
    func pipDidChangeActive(_ active: Bool)
    func pipSetPlaying(_ playing: Bool)
    func pipSkip(by seconds: Double)
    var pipIsPlaying: Bool { get }
    var pipDuration: Double { get }
    func pipRestoreUserInterface(_ completion: @escaping (Bool) -> Void)
}

/// Картинка в картинке поверх AVSampleBufferDisplayLayer, в который рисует mpv (vo=avfoundation).
/// Кадры и их тайминг ведёт mpv; controlTimebase нужен только системному окну PiP для полоски прогресса.
final class PiPController: NSObject {
    private var controller: AVPictureInPictureController?
    private weak var layer: AVSampleBufferDisplayLayer?
    private var timebase: CMTimebase?
    weak var delegate: PiPControllerDelegate?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    init?(layer: AVSampleBufferDisplayLayer, delegate: PiPControllerDelegate) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        self.layer = layer
        self.delegate = delegate
        super.init()

        var tb: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                           sourceClock: CMClockGetHostTimeClock(),
                                           timebaseOut: &tb) == noErr, let tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 0)
            layer.controlTimebase = tb
            timebase = tb
        }

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = false
        self.controller = controller
    }

    /// Автоматический PiP, когда смахиваешь приложение на домашний экран во время просмотра.
    func setAutoStart(_ enabled: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    /// Вызывается из тика плеера: держим системный таймлайн PiP в курсе позиции и паузы.
    func update(position: Double, rate: Double) {
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: max(position, 0), preferredTimescale: 1000))
            CMTimebaseSetRate(timebase, rate: rate)
        }
        if isActive { controller?.invalidatePlaybackState() }
    }

    func invalidate() {
        controller?.delegate = nil
        if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
        layer?.controlTimebase = nil
        controller = nil
        timebase = nil
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        delegate?.pipDidChangeActive(true)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        delegate?.pipDidChangeActive(false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        delegate?.pipDidChangeActive(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if let delegate {
            delegate.pipRestoreUserInterface(completionHandler)
        } else {
            completionHandler(true)
        }
    }
}

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        delegate?.pipSetPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let duration = delegate?.pipDuration ?? 0
        guard duration > 0 else { return CMTimeRange(start: .zero, duration: .positiveInfinity) }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !(delegate?.pipIsPlaying ?? false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        delegate?.pipSkip(by: skipInterval.seconds)
        completionHandler()
    }
}
