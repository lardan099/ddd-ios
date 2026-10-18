import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var router: Router
    @State private var link = ""
    @State private var history: [HistoryEntry] = []
    @AppStorage(AppSettings.hwdecKey) private var hwdec = true
    @AppStorage(AppSettings.languageKey) private var language = ""
    @State private var confirmClear = false
    @ObservedObject private var torr = TorrServerManager.shared
    @AppStorage(AppSettings.torrServerEnabledKey) private var torrEnabled = false
    @AppStorage(AppSettings.torrServerKeepAliveKey) private var torrKeepAlive = true
    @AppStorage(AppSettings.videoOutputKey) private var videoOutput = VideoOutput.avfoundation.rawValue
    @AppStorage(AppSettings.hdrKey) private var hdr = true
    @AppStorage(AppSettings.autoPiPKey) private var autoPiP = true
    @AppStorage(AppSettings.skipModeKey) private var skipMode = AppSettings.SkipMode.button.rawValue
    @State private var pluginCopied = false
    @AppStorage(AppSettings.autoNextKey) private var autoNext = true
    @AppStorage(AppSettings.lampaURLKey) private var lampaURL = AppSettings.defaultLampaURL
    @AppStorage(AppSettings.lampaEnabledKey) private var lampaEnabled = true
    @State private var pendingLampaMarks = 0

    static let pluginURL = "https://lardan099.github.io/lampa-player-plugin/lampa-player.js"

    private struct LanguageOption: Identifiable {
        let id: String
        let title: String
    }

    private let languages = [
        LanguageOption(id: "", title: "Как в системе"),
        LanguageOption(id: "ru", title: "Русский"),
        LanguageOption(id: "uk", title: "Українська"),
        LanguageOption(id: "en", title: "English"),
    ]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Адрес Lampa, например lampa.mx", text: $lampaURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Toggle("Открывать Lampa при запуске", isOn: $lampaEnabled)
                    if router.showLampa {
                        Button("Экран плеера вместо Lampa") {
                            router.showSettings = false
                            router.showLampa = false
                        }
                    } else {
                        Button("Открыть Lampa") { router.showLampa = true }
                            .disabled(AppSettings.normalizedLampaURL(lampaURL) == nil)
                    }
                } header: {
                    Text("Lampa")
                } footer: {
                    Text("Lampa открывается прямо в приложении: плагин подключается сам, видео сразу идёт в этот плеер, отметки просмотра возвращаются напрямую. Настройки плеера — пункт «Lampa Player» в меню Lampa.")
                }

                Section {
                    TextField("http://… или ссылка infuse://, senplayer://", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.go)
                        .onSubmit(openLink)
                    HStack {
                        Button {
                            if let text = UIPasteboard.general.string { link = text }
                        } label: {
                            Label("Вставить", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("Открыть", action: openLink)
                            .buttonStyle(.borderedProminent)
                            .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Открыть ссылку")
                }

                if !history.isEmpty {
                    Section {
                        ForEach(history) { entry in
                            Button { resume(entry) } label: { historyRow(entry) }
                        }
                        .onDelete { offsets in
                            for i in offsets { HistoryStore.remove(id: history[i].id) }
                            reload()
                        }
                    } header: {
                        Text("Недавнее")
                    }
                }

                Section {
                    HStack {
                        Text(Self.pluginURL)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = Self.pluginURL
                            pluginCopied = true
                        } label: {
                            Image(systemName: pluginCopied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                    Picker("Заставки и реклама", selection: $skipMode) {
                        ForEach(AppSettings.SkipMode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    if pendingLampaMarks > 0 {
                        Text("Ждут отправки в Lampa: \(pendingLampaMarks) — откройте Lampa, плагин заберёт их сам.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Плагин для Lampa")
                } footer: {
                    Text("Lampa → Настройки → Расширения → Добавить плагин → вставьте адрес выше. Тип плеера оставьте «Infuse». С плагином приходят все субтитры, метки пропуска заставок и рекламы, превью кадров, а отметки просмотра возвращаются в Lampa — и для онлайна, и для торрентов.")
                }

                Section {
                    Toggle("Встроенный TorrServer", isOn: Binding(
                        get: { torrEnabled },
                        set: { value in
                            torrEnabled = value
                            torr.setEnabled(value)
                        }
                    ))
                    .disabled(torr.busy)
                    HStack {
                        Text("Состояние")
                        Spacer()
                        if torr.busy {
                            ProgressView()
                        } else {
                            Text(torr.running ? "работает" : "остановлен")
                                .foregroundColor(torr.running ? .green : .secondary)
                        }
                    }
                    if let error = torr.lastError {
                        Text(error).font(.footnote).foregroundColor(.red)
                    }
                    if torrEnabled {
                        HStack {
                            Text("Адрес для Lampa")
                            Spacer()
                            Text(TorrServerManager.address)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        Button {
                            UIPasteboard.general.string = TorrServerManager.address
                        } label: {
                            Label("Скопировать адрес", systemImage: "doc.on.doc")
                        }
                        HStack {
                            Button("Проверить") { torr.selfTest() }
                                .buttonStyle(.borderless)
                                .disabled(!torr.running)
                            Spacer()
                            if let result = torr.selfTestResult {
                                Text(result)
                                    .font(.footnote)
                                    .foregroundColor(result.hasPrefix("Отвечает") ? .green : .secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        NavigationLink("Журнал запросов Lampa") { TorrServerLogView() }
                        Toggle("Работать в фоне", isOn: $torrKeepAlive)
                        Button {
                            if let url = URL(string: TorrServerManager.address) { UIApplication.shared.open(url) }
                        } label: {
                            Label("Открыть веб-интерфейс TorrServer", systemImage: "safari")
                        }
                        .disabled(!torr.running)
                    }
                } header: {
                    Text("TorrServer")
                } footer: {
                    Text("Торренты качаются прямо на телефоне, без отдельного сервера. В Lampa: Настройки → TorrServer → адрес \(TorrServerManager.address). «Работать в фоне» не даёт iOS заморозить сервер, пока Lampa открыта в Safari: приложение проигрывает тишину, это тратит немного батареи.")
                }

                Section {
                    Picker("Видеовывод", selection: $videoOutput) {
                        Text("AVFoundation — PiP и HDR").tag(VideoOutput.avfoundation.rawValue)
                        Text("libplacebo — без PiP").tag(VideoOutput.gpuNext.rawValue)
                    }
                    Toggle("HDR", isOn: $hdr)
                    Toggle("Картинка в картинке при сворачивании", isOn: $autoPiP)
                } header: {
                    Text("Видео")
                } footer: {
                    Text("AVFoundation умеет картинку в картинке и настоящий HDR (iOS 17+). libplacebo точнее показывает цвета Dolby Vision profile 5 (часто в WEB-DL): если такое видео фиолетово-зелёное, переключитесь на него. Настройки применяются к следующему открытому видео.")
                }

                Section {
                    Picker("Язык озвучки и субтитров", selection: $language) {
                        ForEach(languages) { item in
                            Text(item.title).tag(item.id)
                        }
                    }
                    Toggle("Аппаратное декодирование", isOn: $hwdec)
                    Toggle("Отсчёт до следующей серии", isOn: $autoNext)
                    if !history.isEmpty {
                        Button("Очистить историю", role: .destructive) { confirmClear = true }
                    }
                } header: {
                    Text("Настройки")
                } footer: {
                    Text("Озвучка и субтитры выбираются автоматически по этому языку. Если на каком-то видео артефакты или зелёный экран, выключите аппаратное декодирование.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. В Lampa: Настройки → Плеер → тип плеера **Infuse** (и для торрентов тоже). Так приходят плейлист серий, позиция и субтитры.")
                        Text("2. Вариант попроще — **SenPlayer**: придёт только одна ссылка.")
                        Text("3. Настоящие Infuse и SenPlayer на телефоне держать не надо, иначе iOS может открыть их вместо этого плеера.")
                        Text("4. Для торрентов в Lampa укажите TorrServer: встроенный (раздел выше) или свой на компьютере/VPS.")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                } header: {
                    Text("Как подключить к Lampa")
                } footer: {
                    Text("Версия \(Self.appVersion)")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .navigationTitle("Lampa Player")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if router.showLampa {
                        Button("Готово") { router.showSettings = false }
                    }
                }
            }
            .confirmationDialog("Очистить историю и позиции просмотра?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Очистить", role: .destructive) {
                    HistoryStore.clear()
                    ResumeStore.clearAll()
                    reload()
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: reload)
        .onChange(of: router.playerVisible) { visible in
            if !visible { reload() }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        let item = entry.items[min(entry.index, entry.items.count - 1)]
        return VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .foregroundColor(.primary)
                .lineLimit(2)
            HStack(spacing: 8) {
                if entry.items.count > 1 {
                    Text("\(entry.index + 1) из \(entry.items.count)")
                }
                Text(entry.updated.formatted(.relative(presentation: .named)))
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if let progress = ResumeStore.progress(for: item.resumeKey), progress > 0 {
                ProgressView(value: progress)
                    .tint(progress >= 1 ? .green : .accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func openLink() {
        guard let request = LaunchParser.parse(text: link) else {
            router.fail(link)
            return
        }
        router.present(request)
    }

    private func resume(_ entry: HistoryEntry) {
        router.present(PlaybackRequest(items: entry.items, startIndex: entry.index, source: "history"))
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func reload() {
        history = HistoryStore.load()
        pendingLampaMarks = LampaProgressStore.pendingCount
    }
}
