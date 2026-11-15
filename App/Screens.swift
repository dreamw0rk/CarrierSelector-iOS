import SwiftUI
import UniformTypeIdentifiers

struct ConnectionScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @ViewState<Bool> private var importing = false
    @ViewState<String?> private var importError: String? = nil
    private var hasPairing: Bool { model.hasPairing }
    @ViewState<Bool> private var deletingPairing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            Image(systemName: hasPairing ? "key.fill" : "link")
                                .foregroundStyle(CarrierStyle.accent).font(.title3)
                                .frame(width: 42, height: 42)
                                .background(CarrierStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hasPairing ? "Готово к подключению" : "Подключите свой iPhone").font(.headline)
                                Text(hasPairing ? "Remote Pairing сохранён" : "Один раз создайте или импортируйте ключ")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if hasPairing {
                            Button {
                                model.connect()
                            } label: {
                                Label("Прочитать SIM", systemImage: "arrow.triangle.2.circlepath")
                            }.buttonStyle(CarrierActionStyle()).disabled(model.busy)
                        }
                        if hasPairing {
                            DisclosureGroup("Настройки подключения") { pairingButtons }
                        } else { pairingButtons }
                        AutomaticPairingView(coordinator: model.pairing)
                        Divider()
                        if model.busy { ProgressView(model.status).font(.subheadline) }
                        else { Label(model.status, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                        OperationErrorContent()
                    }.padding(.vertical, 6)
                } header: {
                    Text("Подключение")
                } footer: {
                    Text("Для подключения включите Wi-Fi и LocalDevVPN.")
                }
                if let device = model.device {
                    Section("Устройство") {
                        ValueRow(title: "Модель", value: device.product)
                        ValueRow(title: "iOS", value: device.version)
                        ValueRow(title: "Прочитано SIM", value: String(device.lines.count))
                    }
                }
                ConnectionStatusSection()
                Section {
                    NavigationLink { SetupGuide() } label: { Label("Как подготовить iPhone", systemImage: "list.number") }
                    NavigationLink { HistoryScreen() } label: { Label("История операций", systemImage: "clock") }
                    if hasPairing {
                        Button("Удалить pairing с этого приложения", role: .destructive) { deletingPairing = true }
                            .disabled(model.busy || model.receipt != nil)
                    }
                }
                if let error = library.errorMessage { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                CreditsSection()
            }
            .carrierScreen()
            .navigationTitle("Подключение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let accessible = url.startAccessingSecurityScopedResource()
                    defer { if accessible { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2_000_000 else { throw CarrierError.message("Pairing-файл слишком большой.") }
                    try PairingStore.save(Data(contentsOf: url))
                    model.pairingChanged()
                } catch { importError = error.localizedDescription }
            }
            .alert("Pairing-файл", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("Понятно", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
            .alert("Удалить pairing?", isPresented: $deletingPairing) {
                Button("Удалить", role: .destructive) {
                    do { try PairingStore.delete(); model.pairingChanged() }
                    catch { importError = error.localizedDescription }
                }
                Button("Отмена", role: .cancel) { }
            } message: { Text("Для следующего подключения создайте или импортируйте pairing заново.") }
        }
    }
    @ViewBuilder private var pairingButtons: some View {
        if PairingSupport.canCreate(onMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            Button(action: model.startAutomaticPairing) {
                Label(hasPairing ? "Создать новый pairing" : "Создать pairing на iPhone", systemImage: "link.badge.plus")
            }.buttonStyle(CarrierActionStyle(prominent: !hasPairing))
                .disabled(model.busy || model.receiptUnreadable)
        } else if !hasPairing {
            Text("На iOS 26 импортируйте pairing-файл с компьютера.").font(.footnote).foregroundStyle(.secondary)
        }
        Button { importing = true } label: {
            Label(hasPairing ? "Заменить pairing-файл" : "Импортировать из Файлов", systemImage: "square.and.arrow.down")
        }.buttonStyle(CarrierActionStyle(prominent: !hasPairing && !PairingSupport.canCreate(onMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)))
            .disabled(model.busy || model.receipt != nil)
    }

}

struct AutomaticPairingView: View {
    @ObservedObject var coordinator: PairingCoordinator
    var body: some View {
        if coordinator.running {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(coordinator.phase).font(.subheadline)
                Text("Выберите «\(coordinator.hostName)» в Настройках → Конфиденциальность и безопасность → Режим разработчика. Подтвердите код в системном окне.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let pin = coordinator.pin {
                    Text(pin).font(.system(.largeTitle, design: .monospaced).bold()).tracking(6)
                        .accessibilityLabel("Код сопряжения: " + pin.map(String.init).joined(separator: " "))
                    Button("Скопировать код") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": pin]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                    }
                    Text("Код также отображается в системной карточке фоновой задачи. Если карточки нет, вернитесь сюда, скопируйте код и введите его в Настройках.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let notice = coordinator.backgroundNotice { Text(notice).font(.footnote).foregroundStyle(.orange) }
                Button("Отменить сопряжение", role: .cancel) { coordinator.cancel() }
            }.padding(.vertical, 8)
        }
    }
}

struct ProfilesScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @ViewState<String> private var query = ""
    @ViewState<Bool> private var onlyFavorites = false
    @AppStorage("profiles.russiaOnly") private var russiaOnly = true
    @AppStorage("profiles.russianOperator") private var operatorID = RussianOperator.all.rawValue
    @AppStorage("profiles.operatorAutomatic") private var automaticOperator = true
    @ViewState<[CarrierProfile]> private var available: [CarrierProfile] = []
    private var selectedOperator: RussianOperator { automaticOperator ? model.inferredOperator ?? .all : RussianOperator(rawValue: operatorID) ?? .all }
    private var filtered: [CarrierProfile] {
        available.filter { profile in
            (!onlyFavorites || library.favorites.contains(profile.identifier)) &&
            (!russiaOnly || model.catalog.research.isCandidate(profile, operator: selectedOperator, hardware: model.device?.hardware)) &&
            ProfileSearch.matches(profile, query: query, research: model.catalog.research)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Название, версия или оператор", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("Поиск профилей")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44).accessibilityLabel("Очистить поиск")
                        }
                    }.frame(minHeight: 44)
                    if !query.isEmpty && russiaOnly {
                        Button("Искать во всём каталоге") { russiaOnly = false; onlyFavorites = false }
                            .font(.subheadline)
                    }
                }
                Section {
                    Text("Откройте профиль, посмотрите его настройки и нажмите «Выбрать для установки».")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let line = model.selectedLine {
                        Label("Для \(line.name) · \(line.maskedIdentity)", systemImage: "simcard").font(.subheadline)
                    } else {
                        Button("Подключить iPhone для подбора по модели") { model.showInstallation() }
                    }
                    NavigationLink { CompareProfilesScreen() } label: { Label("Сравнить два профиля", systemImage: "arrow.left.arrow.right") }
                    Toggle("Только избранное", isOn: $onlyFavorites)
                }
                Section {
                    Toggle("Для российских операторов", isOn: $russiaOnly)
                    if russiaOnly {
                        OperatorFilterPicker()
                        Text("Подборка для выбранного оператора. Доступность услуг зависит от SIM и сети.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.catalog.researchError != nil { Text("Не удалось загрузить описания профилей.").foregroundStyle(.orange) }
                }
                Section("\(filtered.count) профилей") {
                    ForEach(filtered) { profile in
                        NavigationLink { ProfileDetail(profile: profile) } label: {
                            ProfileCatalogRow(profile: profile,
                                operators: model.catalog.research.rules(for: profile, operator: selectedOperator).first(where: \.candidate)?.operatorNames,
                                favorite: library.favorites.contains(profile.identifier))
                        }
                    }
                    if filtered.isEmpty {
                        if russiaOnly {
                            ContentUnavailableView("Профили не найдены", systemImage: "line.3.horizontal.decrease.circle",
                                description: Text("Измените запрос или отключите фильтр «Для российских операторов»."))
                        } else { ContentUnavailableView.search(text: query) }
                    }
                }
                CreditsSection()
            }
            .carrierScreen()
            .navigationTitle("Профили")
            .scrollDismissesKeyboard(.interactively)
            .task { refresh() }
            .onReceive(model.$device) { _ in DispatchQueue.main.async { refresh() } }
        }
    }
    private func refresh() { available = model.catalog.available(for: model.device) }
}

struct ProfileDetail: View {
    let profile: CarrierProfile
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(profile.regionLabel).font(.system(.title, design: .monospaced, weight: .bold))
                            .foregroundStyle(CarrierStyle.accent).frame(width: 68, height: 68)
                            .background(CarrierStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
                        Spacer()
                        Text("v" + profile.version).font(.caption.monospaced().weight(.semibold))
                            .padding(10).background(CarrierStyle.accent.opacity(0.07), in: Capsule())
                    }
                    Text(profile.displayName).font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(profile.bundleName).font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
                LabeledContent("Версия", value: profile.version)
                Button { library.toggle(profile) } label: {
                    Label(library.favorites.contains(profile.identifier) ? "Убрать из избранного" : "В избранное",
                          systemImage: library.favorites.contains(profile.identifier) ? "star.fill" : "star")
                }.disabled(!library.ready)
            }
            if model.selectedLine != nil {
                Section {
                    NavigationLink { ProfileComparisonScreen(profile: profile) } label: {
                        Label("Сравнить с текущим профилем", systemImage: "arrow.left.arrow.right")
                    }
                }
            }
            Section {
                NavigationLink { CompareProfilesScreen(first: profile) } label: { Label("Сравнить с другим профилем", systemImage: "square.on.square") }
            }
            ProfileResearchSections(profile: profile)
            if let error = library.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }
        .carrierScreen()
        .navigationTitle("Профиль").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    if model.receipt != nil { model.showInstallation() }
                    else { model.choose(profile) }
                } label: {
                    Label(model.receipt == nil ? "Выбрать для установки" : "Перейти к текущей установке", systemImage: "arrow.right")
                }.buttonStyle(CarrierActionStyle()).disabled(model.busy)
                Text("SIM и подтверждение — на следующем экране").font(.caption).foregroundStyle(.secondary)
            }.padding().background(.regularMaterial)
        }
    }
}

struct HistoryScreen: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        List {
            Section {
                Picker("SIM", selection: Binding(get: { library.historyFilter ?? "all" }, set: { library.filterHistory($0 == "all" ? nil : $0) })) {
                    Text("Все SIM").tag("all")
                    ForEach(Array(library.historySIMs.enumerated()), id: \.element.id) { index, sim in
                        Text("\(sim.label) · \(index + 1)").tag(sim.id)
                    }
                    Text("Без привязки к SIM").tag("legacy")
                }
            }
            if let error = library.errorMessage { Text(error).foregroundStyle(.red) }
            if library.history.isEmpty { ContentUnavailableView("Пока без операций", systemImage: "clock", description: Text("Для выбранного фильтра нет записей.")) }
            ForEach(library.history) { event in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title).font(.headline)
                        Text(event.detail).font(.subheadline)
                        Text(event.date, format: .dateTime.day().month().year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    if let context = event.context {
                        Text(context.simLabel).font(.subheadline).foregroundStyle(.secondary)
                        ValueRow(title: "Было", value: package(context.previousID, context.previousVersion))
                        ValueRow(title: "Цель", value: package(context.targetID, context.targetVersion))
                        if let active = context.activeID { ValueRow(title: "При проверке", value: package(active, context.activeVersion ?? "")) }
                    }
                }
            }
        }.carrierScreen().navigationTitle("История").toolbar(.visible, for: .navigationBar)
    }
    private func package(_ id: String, _ version: String) -> String {
        id.replacingOccurrences(of: "com.apple.", with: "") + (version.isEmpty ? " · версию выберет iOS" : " · " + version)
    }
}

struct GuideScreen: View {
    @EnvironmentObject private var model: AppModel
    @ViewState<String> private var query = ""
    private let entries: [APNEntry] = Bundle.main.url(forResource: "apn", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([APNEntry].self, from: $0) } ?? []
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { SetupGuide() } label: { Label("Подготовка и подключение", systemImage: "link") }
                    NavigationLink { ServiceCheckGuide() } label: { Label("Как проверить связь после установки", systemImage: "checklist") }
                    NavigationLink { DiagnosticsScreen(diagnostics: model.diagnostics) } label: { Label("Технический отчёт", systemImage: "doc.text") }
                    NavigationLink { HistoryScreen() } label: { Label("История операций", systemImage: "clock") }
                    NavigationLink { AboutScreen() } label: { Label("О приложении и лицензии", systemImage: "info.circle") }
                }
                ForEach(["Россия", "Беларусь"], id: \.self) { country in
                    Section(country) {
                        ForEach(entries.filter { $0.country == country && (query.isEmpty || $0.name.localizedStandardContains(query)) }, id: \.name) { entry in
                            NavigationLink(entry.name) {
                                List {
                                    Section("APN и MMS") { Text(entry.details).textSelection(.enabled).font(.body.monospaced()) }
                                    Section("Где вводить") {
                                        Text("Настройки → Сотовая связь → нужная линия → Сотовая сеть передачи данных.")
                                        Text("Раздел доступен, если операторский пакет разрешает ручное редактирование. Значения IMS/VoLTE/Wi-Fi Calling задаёт пакет.").foregroundStyle(.secondary)
                                    }
                                    Section { Text("Актуальные настройки можно уточнить у оператора.").font(.footnote) }
                                }.carrierScreen().navigationTitle(entry.name)
                            }
                        }
                    }
                }
                CreditsSection()
            }.carrierScreen().navigationTitle("Помощь").searchable(text: $query, prompt: "Найти оператора")
        }
    }
}

struct SetupGuide: View {
    var body: some View {
        List {
            Section("1 · Подготовка") {
                Text("Приложение поддерживает iOS 26.0 и новее, включая iOS 27.")
                Text("Установите CarrierSelector через sideload. Установите LocalDevVPN и включите Wi-Fi.")
                Text("На iOS 27 включите LocalDevVPN и нажмите «Создать pairing на iPhone». В Настройках → Конфиденциальность и безопасность → Режим разработчика выберите службу CarrierSelector и введите показанный приложением код. Ключи сохранятся автоматически после проверки соединения.")
                Text("На iOS 26 создайте Remote Pairing файл для этого iPhone с помощью idevice_pair или iLoader на компьютере и сохраните его в «Файлы». Затем импортируйте в приложение. Импорт также доступен на iOS 27.")
                Link("Получить pairing на компьютере", destination: URL(string: "https://github.com/jkcoxson/idevice_pair")!)
            }
            Section("2 · Подключение") {
                Text("Импортируйте Remote Pairing на вкладке «Установка». Включите LocalDevVPN: адрес устройства 10.7.0.1. Разрешите доступ к локальной сети и нажмите «Прочитать SIM».")
                Text("Используйте Remote Pairing именно этого iPhone.").foregroundStyle(.secondary)
            }
            Section("3 · Установка") {
                Text("На вкладке «Установка» выберите SIM и нажмите «Выбрать профиль». В каталоге откройте профиль и нажмите «Выбрать для установки». Загрузите пакеты, проверьте выбранные SIM и профиль, затем нажмите «Установить профиль». Не закрывайте приложение во время передачи.")
            }
            Section("4 · Проверка") {
                Text("Перезагрузите iPhone вручную. Снова включите LocalDevVPN, откройте приложение и нажмите «Проверить установку».")
            }
            Section("Возврат профиля") {
                Text("На вкладке «Установка» выберите SIM и нажмите «Вернуться к штатному профилю». Нужны LocalDevVPN, Remote Pairing и загруженный каталог. После отправки сброса перезагрузите iPhone, включите VPN и нажмите «Проверить установку».")
                Text("Если штатный оператор SIM не определён, сброс будет недоступен.")
            }
        }.carrierScreen().navigationTitle("Подготовка").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}

struct AboutScreen: View {
    var body: some View {
        List {
            Section("CarrierSelector · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")") {
                Text("Выбор, установка и проверка операторских профилей через LocalDevVPN.")
            }
            Section("Лицензии") {
                ForEach(["CarrierSelector", "idevice", "ZIPFoundation", "CarrierSIM"], id: \.self) { name in
                    NavigationLink(name) {
                        ScrollView {
                            Text(Bundle.main.url(forResource: name + "-LICENSE", withExtension: "txt")
                                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Лицензия недоступна")
                            .font(.footnote.monospaced()).textSelection(.enabled).padding()
                        }.navigationTitle(name)
                    }
                }
                Text("Права на операторские пакеты принадлежат Apple. Они загружаются отдельно из каталога исходного проекта.").font(.footnote)
            }
            CreditsSection()
        }.carrierScreen().navigationTitle("О приложении")
    }
}
