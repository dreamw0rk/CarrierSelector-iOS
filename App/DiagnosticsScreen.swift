import SwiftUI

struct DiagnosticsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var diagnostics: DiagnosticsModel
    @StateObject private var network = LiveNetworkModel()
    @StateObject private var direct = DirectTelephonyModel()
    @ViewState<Bool> private var visible = false
    @ViewState<DiagnosticMode> private var selectedMode = .registration
    private let registration: [DiagnosticMetric] = [.registration, .network, .roaming, .imsVoice, .imsWiFi, .imsServices]
    private let radio: [DiagnosticMetric] = [.rsrp, .sinr]
    private let service: [DiagnosticMetric] = [.volteCapability, .vowifiCapability, .vonrCapability, .saSetting, .epdg, .ikeState, .ikeError]
    private let call: [DiagnosticMetric] = [.callNetwork, .sdpCodec]
    private var measuredSlots: [String] { diagnostics.slots.filter { slot in diagnostics.readings.values.contains { $0.slot == slot } } }

    var body: some View {
        Group {
            List {
                Section {
                    ValueRow(title: "Линия передачи данных", value: network.radio.dataTechnology ?? "iOS не сообщает тип сети")
                    if !network.radio.otherTechnologies.isEmpty {
                        ValueRow(title: "Другие сотовые линии", value: network.radio.otherTechnologies.joined(separator: ", "))
                    }
                    ValueRow(title: "Сетевой маршрут", value: network.route)
                } header: { Text("Сейчас на iPhone") } footer: {
                    Text("Данные iOS обновляются автоматически. Сетевой маршрут учитывает VPN; это не проверка доступа в интернет.")
                }
                Section {
                    if direct.running { ProgressView(direct.phase) }
                    else { Text(direct.phase).font(.subheadline).foregroundStyle(.secondary) }
                    Button { direct.refresh() } label: { Label("Обновить состояние", systemImage: "arrow.clockwise") }
                        .disabled(direct.waitingForCall)
                    if !direct.running {
                        ShareLink(item: diagnostics.report + "\n\n" + direct.report) {
                            Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                        }.disabled(diagnostics.running)
                    }
                } header: { Text("Прямое чтение состояния") } footer: {
                    Text("Без pairing и VPN. Обновляется каждые 15 секунд, пока открыт экран. Соединение IMS само по себе не подтверждает регистрацию голоса или работу VoLTE/VoWiFi.")
                }
                ForEach([0, 1, 2], id: \.self) { slot in
                    let values = direct.readings.filter { $0.slot == slot }
                    if !values.isEmpty {
                        Section {
                            ForEach(values.filter { $0.status == .value }) { reading in
                                ValueRow(title: reading.metric.title, value: reading.text)
                            }
                            if !values.contains(where: { $0.status == .value }) {
                                Text("Данные этой линии недоступны").foregroundStyle(.secondary)
                            }
                            if values.contains(where: { $0.status != .value }) {
                                DisclosureGroup("Ответы iOS") {
                                    ForEach(values.filter { $0.status != .value }) { reading in
                                        ValueRow(title: reading.metric.title, value: reading.text)
                                    }
                                }
                            }
                        } header: { Text(slot == 0 ? "Служба сотовой связи" : "SIM \(slot) · Текущее состояние") } footer: {
                            if let date = values.map(\.date).min() {
                                Text("Прочитано: " + date.formatted(date: .omitted, time: .standard))
                            }
                        }
                    }
                }
                Section {
                    Picker("Проверка", selection: $selectedMode) {
                        ForEach(DiagnosticMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(diagnostics.running)
                    Text((diagnostics.running ? diagnostics.mode : selectedMode).instructions)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if diagnostics.running {
                        ProgressView(diagnostics.phase)
                        Button { diagnostics.stop() } label: { Label("Остановить", systemImage: "stop.fill") }
                            .buttonStyle(CarrierActionStyle(prominent: false)).disabled(diagnostics.stopping)
                        if diagnostics.stats.commCenter > 0 {
                            Label("События связи поступают", systemImage: "waveform.path").font(.subheadline)
                        } else if diagnostics.stats.total > 0 {
                            Text("Журнал подключён. Ожидание событий связи…").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Button { model.startDiagnostics(mode: selectedMode) } label: { Label("Собрать журнал", systemImage: "waveform.path.ecg") }
                            .buttonStyle(CarrierActionStyle()).disabled(model.busy || !model.hasPairing)
                        if diagnostics.ended != nil { Text(diagnostics.phase).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    if !model.hasPairing {
                        Text("Для чтения журнала добавьте pairing на вкладке «Установка» и включите LocalDevVPN.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = diagnostics.error { Text(error).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Журнал IMS и звонков") } footer: {
                    Text("Сбор новых событий до 90 секунд. Скрытые системой значения приложению недоступны.")
                }
                if diagnostics.ended != nil && diagnostics.stats.commCenter > 0 {
                    Section {
                        ForEach([DiagnosticMetric.imsVoice, .imsWiFi, .rsrp, .sinr, .sdpCodec]) { metric in
                            ValueRow(title: metric.title, value: (diagnostics.stats.coverage[metric] ?? DiagnosticFieldCoverage()).status)
                        }
                    } header: { Text("Доступность показателей") } footer: {
                        Text("«Скрыто iOS» означает, что скрыто именно значение этого поля. «Нет результата» — событие есть, но однозначный показатель не извлечён.")
                    }
                }
                if !diagnostics.profiles.isEmpty {
                    Section {
                        ForEach(diagnostics.profiles.keys.sorted(), id: \.self) { slot in
                            ValueRow(title: slotTitle(slot), value: diagnostics.profiles[slot] ?? "")
                        }
                    } header: { Text("Установленные профили") } footer: {
                        Text("Прочитаны с iPhone. Возможности профиля доступны в каталоге.")
                    }
                }
                ForEach(measuredSlots, id: \.self) { slot in
                    Section {
                        metricRows(registration + radio + call, slot: slot)
                        if service.contains(where: { diagnostics.reading($0, slot: slot) != nil }) {
                            DisclosureGroup("Дополнительно") { metricRows(service, slot: slot) }
                        }
                    } header: { Text(slotTitle(slot) + " · События связи") } footer: {
                        Text("Последние полученные события; время указано под значениями. Поддержка услуги и параметры SIP/SDP не подтверждают качество звонка.")
                    }
                }
                if diagnostics.ended != nil && !diagnostics.stats.hasDetailedMetrics {
                    Section {
                        Label("Нет подробных показателей", systemImage: "info.circle")
                        Text("В журнале этой сессии нет распознанных IMS, сигнала или параметров звонка. Прямые ответы iOS показаны выше; дополнительные измерения можно посмотреть в Field Test.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": "*3001#12345#*"]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                    } label: { Label("Скопировать код Field Test", systemImage: "doc.on.doc") }
                } footer: { Text("Вставьте код в приложении «Телефон» и нажмите вызов.") }
                if diagnostics.started != nil || diagnostics.ended != nil {
                    Section {
                        DisclosureGroup("Сведения о проверке") {
                            if let device = diagnostics.deviceDescription { Text(device).font(.subheadline) }
                            ValueRow(title: "Событий журнала", value: String(diagnostics.stats.total))
                            ValueRow(title: "Событий связи", value: String(diagnostics.stats.commCenter))
                            ValueRow(title: "Скрытые значения", value: String(diagnostics.stats.redacted))
                            ValueRow(title: "С распознанными показателями", value: String(diagnostics.stats.parsed))
                            ValueRow(title: "Попыток переподключения", value: String(diagnostics.stats.reconnectAttempts))
                            ShareLink(item: diagnostics.report + "\n\n" + direct.report) { Label("Поделиться отчётом", systemImage: "square.and.arrow.up") }
                                .disabled(diagnostics.running)
                        }
                    } footer: { Text("В отчёте — версия системы, счётчики, состояния услуг и коды ошибок. Номеров SIM и содержимого журнала нет.") }
                }
                CreditsSection()
            }
            .carrierScreen().navigationTitle("Технический отчёт").navigationBarTitleDisplayMode(.inline)
            .onAppear { visible = true; network.start(); direct.start() }
            .onDisappear { visible = false; network.stop(); direct.stop() }
            .onChange(of: scenePhase) { _, phase in
                guard visible else { return }
                if phase == .active { network.start(); direct.start() } else { network.stop(); direct.stop() }
            }
        }
    }
    private func slotTitle(_ slot: String) -> String {
        slot == "kOne" ? "SIM 1" : slot == "kTwo" ? "SIM 2" : "SIM не определена"
    }
    @ViewBuilder private func metricRows(_ metrics: [DiagnosticMetric], slot: String) -> some View {
        ForEach(metrics.filter { diagnostics.reading($0, slot: slot) != nil }) { metric in
            if let reading = diagnostics.reading(metric, slot: slot) {
                VStack(alignment: .leading, spacing: 5) {
                    ValueRow(title: metric.title, value: reading.value)
                    Text((reading.timestampIsReceipt ? "Получено: " : "Событие: ") + reading.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.vertical, 3)
            }
        }
    }
}
