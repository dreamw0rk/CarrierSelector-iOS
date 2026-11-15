import SwiftUI

struct ProfileResearchSections: View {
    let profile: CarrierProfile
    @EnvironmentObject private var model: AppModel
    @AppStorage("profiles.russianOperator") private var operatorID = RussianOperator.all.rawValue
    @AppStorage("profiles.operatorAutomatic") private var automaticOperator = true
    private var selectedOperator: RussianOperator { automaticOperator ? model.inferredOperator ?? .all : RussianOperator(rawValue: operatorID) ?? .all }
    private var research: ProfileResearch { model.catalog.research }
    private var notes: [RussiaRule] { research.rules(for: profile, operator: selectedOperator) }
    private var candidate: Bool {
        research.isCandidate(profile, operator: selectedOperator, hardware: model.device?.hardware)
    }

    var body: some View {
        Section {
            forecast("VoLTE", key: \.volte, yes: "Включён по умолчанию", no: "Выключен по умолчанию")
            forecast("VoWiFi", key: \.wifiWithoutEntitlement, yes: "Без подтверждения оператора-донора", no: "Нужно подтверждение оператора-донора")
            forecast("EVS", key: \.evs, yes: "Есть в настройках", no: "Нет в списке кодеков")
            forecast("5G", key: \.fiveGSwitch, yes: "Переключатель доступен", no: "Переключатель скрыт")
        } header: { Text("Настройки в пакете") } footer: {
            Text("Эти параметры записаны в профиле. Работу VoLTE, VoWiFi и 5G определяют также SIM и сеть оператора.")
        }
        Section {
            OperatorFilterPicker()
            Label(candidate ? "В подборке для России" : "Не входит в подборку",
                  systemImage: candidate ? "checklist" : "info.circle")
                .foregroundStyle(candidate ? CarrierStyle.accent : Color.secondary)
            if notes.isEmpty {
                Text("Нет сведений о работе с этим оператором.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 8) {
                    Text(note.operatorNames).font(.headline)
                    Text(note.summary ?? note.reason)
                    ForEach(note.limitations, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }.font(.subheadline).padding(.vertical, 4)
            }
            ForEach(research.blockers(for: profile, hardware: model.device?.hardware), id: \.self) { blocker in
                Label(blocker, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
            }
            if model.device == nil {
                Text("Подключите iPhone, чтобы уточнить совместимость.").font(.footnote).foregroundStyle(.secondary)
            }
            if model.catalog.researchError != nil { Text("Не удалось загрузить описания профилей.").foregroundStyle(.orange) }
        } header: { Text("Российские операторы") }
        Section {
            DisclosureGroup("Все настройки") {
                ForEach(research.rows(for: profile, hardware: model.device?.hardware)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.subheadline)
                        Text(row.value).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if research.rows(for: profile, hardware: model.device?.hardware).isEmpty {
                    Text("Нет данных для этой модели iPhone.").foregroundStyle(.secondary)
                }
            }
        }
    }
    private func forecast(_ title: String, key: KeyPath<ProfileCapabilities, Bool?>, yes: String, no: String) -> some View {
        let settings = research.settings(for: profile, hardware: model.device?.hardware)
        let values = Set(settings.map { $0[keyPath: key] })
        let text = values.count > 1 ? "Зависит от модели iPhone" : values.first.flatMap { $0 }.map { $0 ? yes : no } ?? "Не указано"
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
