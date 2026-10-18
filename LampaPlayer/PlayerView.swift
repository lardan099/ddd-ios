import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

struct MPVVideoContainer: UIViewRepresentable {
    let view: MPVVideoView
    func makeUIView(context: Context) -> MPVVideoView { view }
    func updateUIView(_ uiView: MPVVideoView, context: Context) {}
}

/// Системная громкость. Публичного API нет, поэтому двигаем ползунок скрытого MPVolumeView.
/// Пока он в иерархии окон, iOS не показывает свой HUD громкости.
final class SystemVolume {
    static let shared = SystemVolume()
    let view: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 120, height: 40))
        v.alpha = 0.0001
        v.isUserInteractionEnabled = false
        return v
    }()

    var current: Double { Double(AVAudioSession.sharedInstance().outputVolume) }

    func set(_ value: Double) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = Float(min(max(value, 0), 1))
    }
}

struct VolumeViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        container.addSubview(SystemVolume.shared.view)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct HideSystemOverlays: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            // Системные жесты НЕ откладываем: иначе первый свайп за шторку или домой достаётся
            // плееру и дёргает яркость/громкость. От случайных срабатываний защищают мёртвые зоны у краёв.
            content
                .persistentSystemOverlays(.hidden)
        } else {
            content
        }
    }
}

/// Кнопка-иконка с зоной нажатия 44×44, а не размером с глиф.
private struct IconButton: View {
    let systemName: String
    var size: CGFloat = 22
    var box: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: box, height: box)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum Adjustment: Equatable {
    case brightness(Double)
    case volume(Double)
}

/// Что делает текущий свайп: решается по первым пикселям движения.
private enum DragMode {
    case brightness(Double)
    case volume(Double)
    case seek(Double)
    /// Свайп от края экрана (системный жест) — до конца жеста ничего не делаем.
    case ignored
}

struct PlayerView: View {
    @StateObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var sheet: PlayerSheet?
    @State private var showLog = false
    @State private var adjustment: Adjustment?
    @State private var dragMode: DragMode?
    @State private var seekPreview: (target: Double, delta: Double)?
    @State private var adjustHideToken = 0
    @State private var originalBrightness: CGFloat?
    @State private var locked = false
    @State private var showUnlock = false
    @State private var unlockHideToken = 0

    /// Сколько секунд перемотки даёт свайп на всю ширину экрана.
    private let seekSpan: Double = 120

    init(request: PlaybackRequest) {
        _model = StateObject(wrappedValue: PlayerModel(request: request))
    }

    private var isPortrait: Bool { verticalSizeClass == .regular }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MPVVideoContainer(view: model.videoView)
                .ignoresSafeArea()

            VolumeViewHost()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)

            gestureLayer

            if model.loading || model.buffering {
                loadingIndicator
                    .allowsHitTesting(false)
            }

            if !locked && (model.controlsVisible || model.errorMessage != nil) {
                controls
                    .transition(.opacity)
            }

            if let adjustment {
                adjustmentIndicator(adjustment)
                    .allowsHitTesting(false)
            }

            if let seekPreview {
                seekPreviewView(seekPreview)
                    .allowsHitTesting(false)
            }

            if let toast = model.toast {
                Text(toast)
                    .font(.headline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 80)
                    .allowsHitTesting(false)
            }

            if let offer = model.resumeOffer, !model.loading, model.errorMessage == nil, !locked {
                VStack {
                    Spacer()
                    HStack {
                        resumeBanner(offer)
                        Spacer()
                    }
                }
                .padding(.leading, 24).padding(.bottom, 130)
            }

            if let seconds = model.nextCountdown, model.errorMessage == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        nextEpisodeCard(seconds)
                    }
                }
                .padding(.trailing, 24)
                .padding(.bottom, model.controlsVisible ? 130 : 40)
                .transition(.opacity)
            } else if let segment = model.activeSegment, !locked, model.errorMessage == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { model.skipActiveSegment() } label: {
                            Label(segment.kind == .ad ? "Пропустить рекламу" : "Пропустить",
                                  systemImage: "forward.end.fill")
                                .font(.headline)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(Color.white.opacity(0.92))
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 24)
                .padding(.bottom, model.controlsVisible ? 130 : 40)
                .transition(.opacity)
            }

            if locked && showUnlock {
                unlockButton
            }

            if let error = model.errorMessage {
                errorPanel(error)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: showUnlock)
        .statusBar(hidden: true)
        .modifier(HideSystemOverlays())
        .preferredColorScheme(.dark)
        .onAppear {
            Orientation.lock(.allButUpsideDown)
            UIApplication.shared.isIdleTimerDisabled = true
            originalBrightness = UIScreen.main.brightness
            TorrServerManager.shared.playerActive = true
            AudioSession.activate()
            model.start()
        }
        .onDisappear {
            model.shutdown()
            UIApplication.shared.isIdleTimerDisabled = false
            if let originalBrightness { UIScreen.main.brightness = originalBrightness }
            TorrServerManager.shared.playerActive = false
            AudioSession.deactivate()
            Orientation.lock(.all)
            openSuccessCallback()
            // Встроенная Lampa сразу ставит отметки просмотра.
            NotificationCenter.default.post(name: .lampaPlayerDidClose, object: nil)
        }
        .onChange(of: model.finished) { finished in
            if finished { dismiss() }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .playlist: PlaylistSheet(model: model)
            case .audio: TrackSheet(model: model, kind: .audio)
            case .subtitles: TrackSheet(model: model, kind: .subtitles)
            case .tuning: TuningSheet(model: model)
            case .tech: TechSheet(model: model)
            }
        }
    }

    // MARK: - Жесты

    /// Левая половина: двойной тап −10 с, свайп вверх/вниз — яркость.
    /// Правая половина: двойной тап +10 с, свайп вверх/вниз — громкость.
    /// Свайп влево/вправо в любом месте — перемотка с превью. Щипок — вписать/заполнить.
    private var gestureLayer: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                sideZone(left: true, size: geo.size)
                sideZone(left: false, size: geo.size)
            }
        }
        .ignoresSafeArea()
        .gesture(
            MagnificationGesture().onEnded { scale in
                guard !locked else { return }
                if scale > 1.1 { model.setFill(true) } else if scale < 0.9 { model.setFill(false) }
            }
        )
    }

    private func sideZone(left: Bool, size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !locked else { return }
                model.seek(by: left ? -10 : 10)
            }
            .onTapGesture {
                if locked { flashUnlock() } else { model.toggleControls() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag in dragChanged(drag, left: left, size: size) }
                    .onEnded { _ in dragEnded() }
            )
    }

    private func dragChanged(_ drag: DragGesture.Value, left: Bool, size: CGSize) {
        guard !locked else { return }
        if dragMode == nil {
            // Свайп начался у верхнего/нижнего края — это шторка, Пункт управления или «домой», не наш жест.
            let edge: CGFloat = 60
            if drag.startLocation.y < edge || drag.startLocation.y > size.height - edge {
                dragMode = .ignored
                return
            }
            let dx = abs(drag.translation.width), dy = abs(drag.translation.height)
            if dy > dx * 1.5, dy > 20 {
                dragMode = left ? .brightness(Double(UIScreen.main.brightness)) : .volume(SystemVolume.shared.current)
            } else if dx > dy * 1.5, model.clock.duration > 0 {
                dragMode = .seek(model.clock.position)
            } else {
                return
            }
        }
        switch dragMode {
        case .brightness(let start):
            let value = min(max(start - Double(drag.translation.height) / Double(max(size.height * 0.6, 1)), 0), 1)
            UIScreen.main.brightness = CGFloat(value)
            adjustment = .brightness(value)
        case .volume(let start):
            let value = min(max(start - Double(drag.translation.height) / Double(max(size.height * 0.6, 1)), 0), 1)
            SystemVolume.shared.set(value)
            adjustment = .volume(value)
        case .seek(let start):
            let duration = model.clock.duration
            let target = min(max(start + Double(drag.translation.width) / Double(max(size.width, 1)) * seekSpan, 0), duration)
            model.clock.scrubTime = target
            seekPreview = (target, target - start)
            model.thumbnails.request(time: target)
        case .ignored, .none:
            break
        }
    }

    private func dragEnded() {
        if case .seek = dragMode, let target = model.clock.scrubTime {
            model.clock.scrubTime = nil
            model.seek(to: target)
            seekPreview = nil
        }
        dragMode = nil
        adjustHideToken += 1
        let token = adjustHideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if token == adjustHideToken { withAnimation { adjustment = nil } }
        }
    }

    private func flashUnlock() {
        showUnlock = true
        unlockHideToken += 1
        let token = unlockHideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if token == unlockHideToken { showUnlock = false }
        }
    }

    private var unlockButton: some View {
        VStack(spacing: 8) {
            Button {
                locked = false
                showUnlock = false
                model.poke()
            } label: {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            Text("Разблокировать")
                .font(.caption)
        }
        .foregroundColor(.white)
    }

    private func adjustmentIndicator(_ adjustment: Adjustment) -> some View {
        let icon: String
        let value: Double
        let alignment: Alignment
        switch adjustment {
        case .brightness(let v):
            icon = "sun.max.fill"; value = v; alignment = .leading
        case .volume(let v):
            icon = v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"; value = v; alignment = .trailing
        }
        return VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(height: 140 * value)
            }
            .frame(width: 6, height: 140)
            Text("\(Int((value * 100).rounded()))")
                .font(.caption.monospacedDigit())
        }
        .foregroundColor(.white)
        .padding(.vertical, 14).padding(.horizontal, 12)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(.horizontal, isPortrait ? 24 : 60)
    }

    private func nextEpisodeCard(_ seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Следующая серия через \(seconds)")
                .font(.headline.monospacedDigit())
            if let title = model.nextTitle {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Button { model.playNextNow() } label: {
                    Label("Смотреть", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.white)
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { model.cancelNextCountdown() } label: {
                    Text("Отмена")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(.white)
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func seekPreviewView(_ preview: (target: Double, delta: Double)) -> some View {
        let sign = preview.delta >= 0 ? "+" : "−"
        return VStack(spacing: 4) {
            ThumbnailImage(provider: model.thumbnails, width: 200)
            Text(PlayerModel.formatTime(preview.target))
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
            Text(sign + PlayerModel.formatTime(abs(preview.delta)))
                .font(.headline.monospacedDigit())
                .foregroundColor(.white.opacity(0.75))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Элементы управления

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.7), .clear, .clear, Color.black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                centerButtons
                Spacer(minLength: 0)
                actionRow
                BottomBar(clock: model.clock, thumbnails: model.thumbnails) { model.seek(to: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.top, isPortrait ? 8 : 20)
            .padding(.bottom, 12)
        }
        .foregroundColor(.white)
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            IconButton(systemName: "xmark") { dismiss() }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.current.displayTitle)
                    .font(.headline)
                    .lineLimit(isPortrait ? 2 : 1)
                if model.items.count > 1 {
                    Text("\(model.index + 1) из \(model.items.count)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.leading, 4)
            .allowsHitTesting(false)
            Spacer(minLength: 8)
            if model.pipAvailable {
                IconButton(systemName: model.pipActive ? "pip.exit" : "pip.enter") { model.togglePiP() }
            }
            IconButton(systemName: "rotate.right") { Orientation.toggle() }
            IconButton(systemName: "lock") {
                locked = true
                model.controlsVisible = false
                flashUnlock()
            }
        }
    }

    /// Озвучка, субтитры, серии и меню — над полосой перемотки, чтобы влезало и вертикально.
    private var actionRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            IconButton(systemName: "waveform") { sheet = .audio }
            IconButton(systemName: model.subTracks.contains(where: { $0.selected }) ? "captions.bubble.fill" : "captions.bubble") {
                sheet = .subtitles
            }
            if model.items.count > 1 {
                IconButton(systemName: "list.bullet") { sheet = .playlist }
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Section("Скорость") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button { model.setSpeed(speed) } label: {
                        if model.playbackSpeed == speed {
                            Label(PlayerModel.formatSpeed(speed), systemImage: "checkmark")
                        } else {
                            Text(PlayerModel.formatSpeed(speed))
                        }
                    }
                }
            }
            Button { model.toggleFill() } label: {
                Label(model.fill ? "Вписать в экран" : "Заполнить экран",
                      systemImage: model.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            if !model.clock.segments.isEmpty || model.current.segments != nil {
                Section("Пропуск заставок и рекламы") {
                    ForEach(AppSettings.SkipMode.allCases, id: \.self) { mode in
                        Button { AppSettings.skipMode = mode; model.showToast(mode.title) } label: {
                            if AppSettings.skipMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                }
            }
            Button { sheet = .tuning } label: {
                Label("Задержка и размер субтитров", systemImage: "slider.horizontal.3")
            }
            Button { sheet = .tech } label: {
                Label("Тех. данные и лог", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var centerButtons: some View {
        let small: CGFloat = isPortrait ? 50 : 60
        return HStack(spacing: isPortrait ? 8 : 28) {
            if model.items.count > 1 {
                IconButton(systemName: "backward.end.fill", size: 24, box: small) { model.previous() }
                    .disabled(!model.hasPrevious)
                    .opacity(model.hasPrevious ? 1 : 0.35)
            }
            IconButton(systemName: "gobackward.10", size: 28, box: small) { model.seek(by: -10) }
            IconButton(systemName: model.paused ? "play.fill" : "pause.fill", size: 42, box: isPortrait ? 66 : 76) { model.togglePause() }
                .opacity(model.loading ? 0 : 1)
            IconButton(systemName: "goforward.10", size: 28, box: small) { model.seek(by: 10) }
            if model.items.count > 1 {
                IconButton(systemName: "forward.end.fill", size: 24, box: small) { model.next() }
                    .disabled(!model.hasNext)
                    .opacity(model.hasNext ? 1 : 0.35)
            }
        }
    }

    // MARK: - Состояния

    private var loadingIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.6)
            Group {
                if model.loading && model.bufferingPercent == nil {
                    Text("Подключение…")
                } else if let percent = model.bufferingPercent {
                    Text("Буферизация \(percent)%")
                }
                if let speed = model.speedText {
                    Text(speed).foregroundColor(.white.opacity(0.7))
                }
            }
            .font(.footnote.monospacedDigit())
            .foregroundColor(.white)
        }
        .padding(.top, model.controlsVisible ? 140 : 0)
    }

    private func resumeBanner(_ offset: Double) -> some View {
        HStack(spacing: 12) {
            Text("Продолжаем с \(PlayerModel.formatTime(offset))")
            Button("С начала") { model.restartFromBeginning() }
                .font(.body.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black.opacity(0.7))
        .clipShape(Capsule())
        .foregroundColor(.white)
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.yellow)
            Text("Не удалось воспроизвести")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.8))
            if showLog, !model.log.isEmpty {
                ScrollView {
                    Text(model.log.joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }
            HStack(spacing: 14) {
                Button("Повторить") { model.retry() }
                    .buttonStyle(.borderedProminent)
                Button(showLog ? "Скрыть лог" : "Лог") { showLog.toggle() }
                    .buttonStyle(.bordered)
                Button("Тех. данные") { sheet = .tech }
                    .buttonStyle(.bordered)
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundColor(.white)
        .padding(24)
        .frame(maxWidth: 520)
        .background(Color(white: 0.1).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding()
    }

    private func openSuccessCallback() {
        // Infuse-схема позволяет Lampa передать x-success. Открываем только «приложенческие» схемы,
        // http-ссылку незачем выкидывать в Safari.
        guard let raw = model.successURL, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https", scheme != "infuse" else { return }
        UIApplication.shared.open(url)
    }
}

struct BottomBar: View {
    @ObservedObject var clock: PlaybackClock
    let thumbnails: ThumbnailProvider
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Scrubber(position: clock.position, duration: clock.duration, cacheEnd: clock.cacheEnd,
                     segments: clock.segments, thumbnails: thumbnails,
                     scrubTime: $clock.scrubTime, onCommit: onSeek)
            HStack {
                Text(PlayerModel.formatTime(clock.scrubTime ?? clock.position))
                Spacer()
                if clock.duration > 0 {
                    Text("−" + PlayerModel.formatTime(max(0, clock.duration - (clock.scrubTime ?? clock.position))))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.white.opacity(0.85))
        }
        .onChange(of: clock.scrubTime) { time in
            thumbnails.request(time: time)
        }
    }
}

struct Scrubber: View {
    let position: Double
    let duration: Double
    let cacheEnd: Double
    var segments: [SkipRange] = []
    var thumbnails: ThumbnailProvider?
    @Binding var scrubTime: Double?
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = scrubTime ?? position
            let fraction = duration > 0 ? min(max(shown / duration, 0), 1) : 0
            let cached = duration > 0 ? min(max(cacheEnd / duration, 0), 1) : 0
            let knob: CGFloat = scrubTime == nil ? 14 : 22

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.white.opacity(0.45)).frame(width: width * cached, height: 4)
                Capsule().fill(Color.accentColor).frame(width: width * fraction, height: 4)
                // Метки пропуска: заставки/титры — жёлтые, реклама — красная.
                if duration > 0 {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let from = min(max(segment.start / duration, 0), 1)
                        let to = min(max(segment.end / duration, 0), 1)
                        Capsule()
                            .fill(segment.kind == .ad ? Color.red.opacity(0.9) : Color.yellow.opacity(0.85))
                            .frame(width: max(width * (to - from), 3), height: 4)
                            .offset(x: width * from)
                    }
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .offset(x: width * fraction - knob / 2)
                if scrubTime != nil, let thumbnails {
                    ThumbnailImage(provider: thumbnails)
                        .offset(x: min(max(width * fraction - 80, 0), max(width - 160, 0)), y: -70)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrubTime = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { value in
                        guard duration > 0 else { scrubTime = nil; return }
                        let target = min(max(value.location.x / width, 0), 1) * duration
                        scrubTime = nil
                        onCommit(target)
                    }
            )
        }
        .frame(height: 30)
    }
}

enum PlayerSheet: String, Identifiable {
    case audio, subtitles, playlist, tuning, tech
    var id: String { rawValue }
}

struct TrackSheet: View {
    enum Kind { case audio, subtitles }

    @ObservedObject var model: PlayerModel
    let kind: Kind
    @Environment(\.dismiss) private var dismiss

    private var tracks: [MediaTrack] { kind == .audio ? model.audioTracks : model.subTracks }

    var body: some View {
        NavigationView {
            List {
                if kind == .subtitles {
                    row(title: "Выключить", details: nil, selected: !tracks.contains(where: { $0.selected })) {
                        model.selectSubtitle(nil)
                    }
                }
                if tracks.isEmpty && kind == .audio {
                    Text("Дорожки появятся после загрузки видео").foregroundColor(.secondary)
                }
                ForEach(tracks) { track in
                    row(title: track.label, details: track.details.isEmpty ? nil : track.details, selected: track.selected) {
                        if kind == .audio { model.selectAudio(track) } else { model.selectSubtitle(track) }
                    }
                }
            }
            .navigationTitle(kind == .audio ? "Озвучка" : "Субтитры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private func row(title: String, details: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundColor(.primary)
                    if let details {
                        Text(details).font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
        }
    }
}

struct PlaylistSheet: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(model.items.enumerated()), id: \.offset) { offset, item in
                    Button {
                        model.play(index: offset)
                        dismiss()
                    } label: {
                        HStack {
                            Text("\(offset + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayTitle)
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                if let progress = ResumeStore.progress(for: item.resumeKey), progress > 0 {
                                    ProgressView(value: progress).tint(progress >= 1 ? .green : .accentColor)
                                }
                            }
                            Spacer()
                            if offset == model.index {
                                Image(systemName: "play.fill").foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }
}
