import SwiftUI
import UIKit

struct MPVVideoContainer: UIViewRepresentable {
    let view: MPVVideoView
    func makeUIView(context: Context) -> MPVVideoView { view }
    func updateUIView(_ uiView: MPVVideoView, context: Context) {}
}

struct PlayerView: View {
    @StateObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: PlayerSheet?
    @State private var showLog = false

    init(request: PlaybackRequest) {
        _model = StateObject(wrappedValue: PlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MPVVideoContainer(view: model.videoView)
                .ignoresSafeArea()

            gestureLayer

            if model.loading || model.buffering {
                loadingIndicator
                    .allowsHitTesting(false)
            }

            if model.controlsVisible || model.errorMessage != nil {
                controls
                    .transition(.opacity)
            }

            if let toast = model.toast {
                Text(toast)
                    .font(.headline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .foregroundColor(.white)
                    .allowsHitTesting(false)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
            }

            if let offer = model.resumeOffer, !model.loading, model.errorMessage == nil {
                resumeBanner(offer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 24).padding(.bottom, 90)
            }

            if let error = model.errorMessage {
                errorPanel(error)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
        .onAppear {
            Orientation.lock(.landscape)
            UIApplication.shared.isIdleTimerDisabled = true
            AudioSession.activate()
            model.start()
        }
        .onDisappear {
            model.shutdown()
            UIApplication.shared.isIdleTimerDisabled = false
            AudioSession.deactivate()
            Orientation.lock(.all)
            openSuccessCallback()
        }
        .onChange(of: model.finished) { finished in
            if finished { dismiss() }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .playlist: PlaylistSheet(model: model)
            case .audio: TrackSheet(model: model, kind: .audio)
            case .subtitles: TrackSheet(model: model, kind: .subtitles)
            }
        }
    }

    // MARK: - Жесты

    private var gestureLayer: some View {
        HStack(spacing: 0) {
            tapZone(seek: -10)
            tapZone(seek: nil)
            tapZone(seek: 10)
        }
        .ignoresSafeArea()
        .gesture(
            MagnificationGesture().onEnded { scale in
                if scale > 1.1 { model.setFill(true) } else if scale < 0.9 { model.setFill(false) }
            }
        )
    }

    private func tapZone(seek delta: Double?) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let delta { model.seek(by: delta) } else { model.toggleFill() }
            }
            .onTapGesture { model.toggleControls() }
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
                Spacer()
                centerButtons
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .foregroundColor(.white)
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.current.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                if model.items.count > 1 {
                    Text("\(model.index + 1) из \(model.items.count)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            Spacer()
            Button { sheet = .audio } label: {
                Image(systemName: "waveform").font(.title3)
            }
            Button { sheet = .subtitles } label: {
                Image(systemName: model.subTracks.contains(where: { $0.selected }) ? "captions.bubble.fill" : "captions.bubble")
                    .font(.title3)
            }
            if model.items.count > 1 {
                Button { sheet = .playlist } label: {
                    Image(systemName: "list.bullet").font(.title3)
                }
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
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
    }

    private var centerButtons: some View {
        HStack(spacing: 44) {
            if model.items.count > 1 {
                Button { model.previous() } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .disabled(!model.hasPrevious)
                .opacity(model.hasPrevious ? 1 : 0.35)
            }
            Button { model.seek(by: -10) } label: {
                Image(systemName: "gobackward.10").font(.title)
            }
            Button { model.togglePause() } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 44))
                    .frame(width: 64, height: 64)
            }
            .opacity(model.loading ? 0 : 1)
            Button { model.seek(by: 10) } label: {
                Image(systemName: "goforward.10").font(.title)
            }
            if model.items.count > 1 {
                Button { model.next() } label: {
                    Image(systemName: "forward.end.fill").font(.title2)
                }
                .disabled(!model.hasNext)
                .opacity(model.hasNext ? 1 : 0.35)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Scrubber(position: model.position, duration: model.duration, cacheEnd: model.cacheEnd,
                     scrubTime: $model.scrubTime) { target in
                model.seek(to: target)
            }
            HStack {
                Text(PlayerModel.formatTime(model.scrubTime ?? model.position))
                Spacer()
                if model.duration > 0 {
                    Text("−" + PlayerModel.formatTime(max(0, model.duration - (model.scrubTime ?? model.position))))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.white.opacity(0.85))
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

struct Scrubber: View {
    let position: Double
    let duration: Double
    let cacheEnd: Double
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
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .offset(x: width * fraction - knob / 2)
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
    case audio, subtitles, playlist
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
