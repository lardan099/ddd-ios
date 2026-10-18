import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var router: Router
    @State private var link = ""
    @State private var history: [HistoryEntry] = []
    @AppStorage(AppSettings.hwdecKey) private var hwdec = true
    @AppStorage(AppSettings.languageKey) private var language = ""
    @State private var confirmClear = false

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
                    Picker("Язык озвучки и субтитров", selection: $language) {
                        ForEach(languages) { item in
                            Text(item.title).tag(item.id)
                        }
                    }
                    Toggle("Аппаратное декодирование", isOn: $hwdec)
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
                        Text("4. Для торрентов в Lampa должен быть указан ваш TorrServer, и телефон должен до него доставать.")
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
        .onChange(of: router.request) { request in
            if request == nil { reload() }
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
    }
}
