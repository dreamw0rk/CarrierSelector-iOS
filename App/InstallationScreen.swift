import SwiftUI

struct InstallationScreen: View {
    @EnvironmentObject private var model: AppModel
    @ViewState<Bool> private var connection = false
    @ViewState<Bool> private var confirmInstall = false
    @ViewState<Bool> private var confirmRestart = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    OverviewHero(hasPairing: model.hasPairing, device: model.device)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if !downloadInBar || model.downloadRetryAvailable { CatalogDownloadSection() }
                if model.busy && model.downloadProgress == nil {
                    Section { ProgressView(model.status) }
                }
                if model.lastError != nil && !model.downloadRetryAvailable {
                    Section { OperationErrorContent(openConnection: { connection = true }) }
                }
                if let notice = model.selectionNotice {
                    Section { Label(notice, systemImage: "info.circle").font(.subheadline) }
                }
                if model.receiptUnreadable {
                    Section {
                        Label("Предыдущая операция недоступна", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text("Сохранённое состояние не удалось прочитать. Новая установка заблокирована, чтобы не перезаписать незавершённую операцию.")
                        NavigationLink("Открыть технический отчёт") { DiagnosticsScreen(diagnostics: model.diagnostics) }
                    }
                } else if let pending = model.receipt {
                    verification(pending)
                } else {
                    if let verified = model.verifiedReceipt {
                        Section {
                            Label(verified.isRestore ? "Штатный профиль активен" : "Установка подтверждена", systemImage: "checkmark.circle.fill")
                                .font(.headline).foregroundStyle(.green)
                            Text(profileTitle(verified.targetID, version: model.verification?.active?.version ?? verified.targetVersion))
                            if let line = model.verification?.active { Text(line.maskedIdentity).font(.subheadline).foregroundStyle(.secondary) }
                            NavigationLink("Как проверить звонки и интернет") { ServiceCheckGuide() }
                        } footer: { Text("iPhone сообщил об активном пакете. Работа услуг проверяется отдельно.") }
                    }
                    preparation
                    if model.device != nil { selection }
                }
                if model.device != nil {
                    Section {
                        if let line = model.selectedLine {
                            NavigationLink { CurrentProfileScreen() } label: {
                                ValueRow(title: line.maskedIdentity, value: profileTitle(line.bundleID, version: line.version))
                            }
                        }
                        Button("Обновить данные iPhone") { model.connect() }.disabled(model.busy)
                        NavigationLink { RestoreProfileScreen() } label: {
                            Label("Вернуться к штатному профилю", systemImage: "arrow.uturn.backward")
                        }
                    } header: { Text("Текущий профиль") } footer: { Text("Данные на момент последнего подключения через LocalDevVPN.") }
                }
                Section {
                    NavigationLink { ServiceCheckGuide() } label: { Label("Как проверить связь", systemImage: "checklist") }
                    Button { connection = true } label: { Label("Настройки подключения", systemImage: "link") }
                    NavigationLink { HistoryScreen() } label: { Label("История операций", systemImage: "clock") }
                }
                CreditsSection()
            }
            .carrierScreen()
            .navigationTitle("Установка")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $connection) { ConnectionScreen() }
            .safeAreaInset(edge: .bottom) { primaryAction }
            .alert("Установить профиль?", isPresented: $confirmInstall) {
                Button("Установить", role: .destructive) {
                    if let profile = model.selectedProfile, let line = model.selectedLine,
                       model.installationBlocker == nil { model.install(profile, line: line) }
                }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("\(model.selectedLine?.maskedIdentity ?? "") → \(model.selectedProfile?.displayName ?? ""), версия \(model.selectedProfile?.version ?? ""). Связь может прерваться. После отправки перезагрузите iPhone.")
            }
            .alert("iPhone перезагружен?", isPresented: $confirmRestart) {
                Button("Проверить") { model.connect(restartConfirmed: true) }
                Button("Отмена", role: .cancel) { }
            } message: { Text("Подтвердите, что вы перезагрузили iPhone и снова включили LocalDevVPN.") }
        }
    }

    private var downloadInBar: Bool {
        !model.receiptUnreadable && model.receipt == nil && model.selectedProfile != nil && model.device != nil
    }
    @ViewBuilder private var primaryAction: some View {
        if !model.receiptUnreadable && (model.receipt != nil || (model.selectedProfile != nil && model.device != nil)) {
            VStack(spacing: 8) {
                if let pending = model.receipt {
                    Text(profileTitle(pending.targetID, version: pending.targetVersion)).font(.subheadline.weight(.semibold))
                    Button { confirmRestart = true } label: {
                        if model.busy { ProgressView("Пожалуйста, подождите…").tint(.white) }
                        else { Label("Проверить установку", systemImage: "checkmark.circle") }
                    }.buttonStyle(CarrierActionStyle()).disabled(model.busy || !model.hasPairing)
                } else if let progress = model.downloadProgress {
                    CatalogProgressContent(progress: progress, cancel: model.cancelCatalogDownload)
                } else if let profile = model.selectedProfile {
                    Text("\(model.selectedLine?.maskedIdentity ?? "SIM не выбрана") → \(profile.displayName) · \(profile.version)")
                        .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if !model.catalog.isDownloaded {
                        Button(action: model.downloadCatalog) {
                            if model.busy { ProgressView("Пожалуйста, подождите…").tint(.white) }
                            else { Label(model.downloadCanResume ? "Продолжить загрузку" : "Загрузить пакеты · 170 МБ", systemImage: "arrow.down.circle") }
                        }.buttonStyle(CarrierActionStyle()).disabled(model.busy)
                    } else {
                        Button { confirmInstall = true } label: {
                            if model.busy { ProgressView("Пожалуйста, подождите…").tint(.white) }
                            else { Label("Установить профиль", systemImage: "arrow.down.to.line") }
                        }.buttonStyle(CarrierActionStyle()).disabled(model.busy || model.installationBlocker != nil)
                    }
                }
            }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
        }
    }

    private var preparation: some View {
        Section {
            if let device = model.device {
                Label("iPhone подключён · iOS \(device.version)", systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                StepHeading(number: "1", title: "Подключите iPhone", detail: "Включите Wi-Fi и LocalDevVPN, чтобы прочитать SIM и текущий профиль.")
                if let profile = model.selectedProfile {
                    Text("Выбран профиль: \(profile.displayName) · \(profile.version)").font(.subheadline)
                }
                Button {
                    if model.hasPairing { model.connect() } else { connection = true }
                } label: {
                    Label(model.hasPairing ? "Прочитать SIM" : "Настроить подключение", systemImage: "link")
                }.buttonStyle(CarrierActionStyle()).disabled(model.busy)
            }
        }
    }

    private var selection: some View {
        Group {
            Section {
                StepHeading(number: "1", title: "Выберите SIM", detail: "Профиль изменится только для этой линии.")
                if let device = model.device, !device.lines.isEmpty {
                    Picker("SIM", selection: Binding(get: { model.selectedLine?.id ?? "" }, set: { model.selectLine($0) })) {
                        if model.selectedLine == nil { Text("Выберите SIM").tag("") }
                        ForEach(device.lines) { line in Text("\(line.name) · \(line.maskedIdentity)").tag(line.id) }
                    }.disabled(model.busy)
                } else {
                    Text("SIM не найдены. Включите нужную линию в настройках сотовой связи и обновите данные.")
                }
            }
            Section {
                StepHeading(number: "2", title: "Выберите профиль", detail: "В каталоге можно посмотреть настройки и подборку для российских операторов.")
                if let profile = model.selectedProfile {
                    NavigationLink { ProfileDetail(profile: profile) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.displayName).font(.headline)
                            Text("\(profile.bundleName) · \(profile.version)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if model.selectedLine != nil {
                        NavigationLink { ProfileComparisonScreen(profile: profile) } label: {
                            Label("Сравнить с текущим профилем", systemImage: "arrow.left.arrow.right")
                        }
                    }
                    Button("Выбрать другой профиль") { model.showProfiles() }.disabled(model.busy)
                } else {
                    Button { model.showProfiles() } label: {
                        Label("Выбрать профиль", systemImage: "square.grid.2x2")
                    }.buttonStyle(CarrierActionStyle()).disabled(model.busy)
                }
            }
            if model.selectedProfile != nil {
                Section {
                    StepHeading(number: "3", title: "Установите и перезагрузите", detail: "Оставьте LocalDevVPN включённым. Не закрывайте приложение во время отправки.")
                    if let blocker = model.installationBlocker {
                        Text(blocker).font(.subheadline).foregroundStyle(.secondary)
                    }
                } footer: { Text("После отправки здесь появится кнопка «Проверить установку».") }
            }
        }
    }

    private func verification(_ pending: InstallReceipt) -> some View {
        Section {
            if let result = model.verification, result.outcome != .restartRequired {
                Label(result.title, systemImage: "exclamationmark.circle").font(.title3.bold())
                Text(result.guidance).font(.subheadline).foregroundStyle(.secondary)
            } else {
                StepHeading(number: "3", title: "Перезагрузите и проверьте", detail: "Отправка ещё не подтверждает, что профиль применился.")
                Text("1. Перезагрузите iPhone вручную.\n2. Снова включите LocalDevVPN.\n3. Вернитесь сюда и проверьте установку.")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            ValueRow(title: "Ожидали", value: profileTitle(pending.targetID, version: pending.targetVersion))
            if let result = model.verification {
                if let line = result.active {
                    ValueRow(title: "Активен", value: profileTitle(line.bundleID, version: line.version))
                    Text(line.maskedIdentity).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Прочитано: " + result.checkedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                if result.outcome != .restartRequired && model.canRestoreStock {
                    NavigationLink { RestoreProfileScreen() } label: {
                        Label("Вернуться к штатному профилю", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            if !model.hasPairing || model.verification?.outcome == .wrongDevice {
                Button("Восстановить подключение") { connection = true }
            }
        } footer: {
            Text("Новая установка доступна после подтверждения результата. Если связь ухудшилась, используйте доступный возврат к штатному профилю.")
        }
    }
}

struct StepHeading: View {
    let number: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(title) } icon: { Text(number).font(.subheadline.bold()) }
                .font(.title3.bold()).accessibilityLabel("Шаг \(number). \(title)")
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}

private func profileTitle(_ identifier: String, version: String) -> String {
    identifier.replacingOccurrences(of: "com.apple.", with: "") + (version.isEmpty ? "" : " · " + version)
}

struct RestoreProfileScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<Bool> private var confirm = false
    var body: some View {
        List {
            Section {
                Text("Возврат к настройкам оператора").font(.title2.bold())
                Text("iOS выберет штатный профиль для SIM. После сброса понадобится перезагрузка и проверка на экране «Установка».")
            }
            Section("Выбранная SIM") {
                if let line = model.selectedLine {
                    ValueRow(title: "Линия", value: line.name + " · " + line.maskedIdentity)
                    ValueRow(title: "Сейчас", value: profileTitle(line.bundleID, version: line.version))
                }
                if let stock = model.stockProfile { ValueRow(title: "Штатный оператор", value: stock.bundleName) }
                else { Text("Штатный оператор не определён однозначно. Сброс недоступен.").foregroundStyle(.secondary) }
            }
            Section {
                if model.receiptUnreadable { Text("Состояние предыдущей операции недоступно. Сброс заблокирован.") }
                else if model.receipt != nil && !model.canRestoreStock {
                    Text("Сначала завершите предыдущую операцию на её SIM и проверьте подключение.")
                }
                if !model.catalog.isDownloaded {
                    Button(model.downloadCanResume ? "Продолжить загрузку" : "Загрузить пакеты · 170 МБ", action: model.downloadCatalog).disabled(model.busy)
                }
                Button("Вернуться к штатному профилю", role: .destructive) { confirm = true }
                    .disabled(!model.canRestoreStock)
            } footer: { Text("Включите LocalDevVPN. Сброс затронет только указанную SIM.") }
            CatalogDownloadSection()
            if model.busy && model.downloadProgress == nil { ProgressView(model.status) }
            if !model.downloadRetryAvailable { OperationErrorContent() }
        }.carrierScreen().navigationTitle("Возврат профиля").navigationBarTitleDisplayMode(.inline)
            .alert("Вернуть штатный профиль?", isPresented: $confirm) {
                Button("Сбросить", role: .destructive) { model.restoreStock(); dismiss() }
                Button("Отмена", role: .cancel) { }
            } message: { Text("\(model.selectedLine?.maskedIdentity ?? "") → \(model.stockProfile?.bundleName ?? ""). Связь может временно прерваться.") }
    }
}

struct ServiceCheckGuide: View {
    var body: some View {
        List {
            Section("Применился ли профиль") {
                Text("После перезагрузки включите LocalDevVPN и нажмите «Проверить установку». Приложение сравнит активный пакет с отправленным для той же SIM.")
                Text("Для обычной установки сравниваются название пакета и версия. При возврате к штатному профилю проверяется оператор; версию выбирает iOS.").foregroundStyle(.secondary)
            }
            Section("Мобильный интернет") {
                Text("Выключите Wi-Fi и LocalDevVPN. Выберите нужную SIM для передачи данных и откройте сайт в Safari.")
            }
            Section("Звонки") {
                Text("Позвоните с выбранной SIM и проверьте звук в обе стороны. Для VoWiFi включите «Вызовы по Wi-Fi» в настройках линии, если этот пункт доступен, и проверьте звонок через Wi-Fi.")
                Text("Приложение не может автоматически подтвердить VoLTE, VoWiFi или кодек EVS на этом iPhone.").foregroundStyle(.secondary)
            }
            Section("Если связь ухудшилась") {
                Text("На экране «Установка» выберите нужную SIM и откройте «Вернуться к штатному профилю». Для сброса снова включите Wi-Fi и LocalDevVPN.")
            }
        }.carrierScreen().navigationTitle("Проверка связи").navigationBarTitleDisplayMode(.inline)
    }
}

/// Lightweight public state, separate from profile verification and tied to visibility.
struct ConnectionStatusSection: View {
    @StateObject private var network = LiveNetworkModel()
    @Environment(\.scenePhase) private var scenePhase
    @ViewState<Bool> private var visible = false
    var body: some View {
        Section {
            if let technology = network.radio.dataTechnology {
                ValueRow(title: "Сеть линии данных", value: technology)
            }
            ValueRow(title: "Сетевой маршрут", value: network.route)
        } header: { Text("Сейчас на iPhone") } footer: {
            Text("Маршрут учитывает VPN. Это не проверка доступа в интернет.")
        }
        .onAppear { visible = true; network.start() }
        .onDisappear { visible = false; network.stop() }
        .onChange(of: scenePhase) { _, phase in
            guard visible else { return }
            if phase == .active { network.start() } else { network.stop() }
        }
    }
}
