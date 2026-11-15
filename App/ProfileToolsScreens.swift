import SwiftUI

struct CurrentProfileScreen: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            if let line = model.selectedLine {
                let exact = ProfileCatalogLookup.exact(identifier: line.bundleID, version: line.version, device: model.device, profiles: model.catalog.profiles)
                let versions = ProfileCatalogLookup.versions(identifier: line.bundleID, device: model.device, profiles: model.catalog.profiles)
                Section("Активен на \(line.maskedIdentity)") {
                    ValueRow(title: "Пакет", value: line.bundleID.replacingOccurrences(of: "com.apple.", with: ""))
                    ValueRow(title: "Версия", value: line.version)
                    if let profile = exact.first {
                        NavigationLink("Открыть настройки профиля") { ProfileDetail(profile: profile) }
                    } else {
                        Text("Этой версии нет в каталоге. Настройки другого выпуска могут отличаться.").foregroundStyle(.secondary)
                    }
                }
                Section("Версии в каталоге") {
                    ForEach(versions) { profile in
                        NavigationLink { ProfileDetail(profile: profile) } label: {
                            HStack {
                                Text(profile.version)
                                if profile.version == line.version { Label("Активна", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if versions.isEmpty { Text("Для этой модели iPhone версии не найдены.").foregroundStyle(.secondary) }
                }
            } else {
                ContentUnavailableView("Выберите SIM", systemImage: "simcard", description: Text("Сначала прочитайте данные iPhone и выберите линию."))
            }
        }.carrierScreen().navigationTitle("Текущий профиль").navigationBarTitleDisplayMode(.inline)
    }
}

struct CompareProfilesScreen: View {
    @EnvironmentObject private var model: AppModel
    @ViewState<CarrierProfile?> private var first: CarrierProfile?
    @ViewState<CarrierProfile?> private var second: CarrierProfile?
    @ViewState<Int?> private var choosing: Int?
    init(first: CarrierProfile? = nil) { _first = ViewState(initialValue: first) }
    var body: some View {
        List {
            Section {
                Button { choosing = 1 } label: { choice("Первый профиль", profile: first) }
                Button { choosing = 2 } label: { choice("Второй профиль", profile: second) }
                if first != nil && second != nil {
                    Button("Поменять местами") { let old = first; first = second; second = old }
                }
            } footer: {
                Text(model.device == nil ? "Без подключения сравниваются все варианты пакета. Различия между платами отмечаются отдельно." : "Сравниваются настройки для подключённого iPhone.")
            }
            if let first, let second {
                let comparison = ProfileComparison(first: first, second: second, device: model.device,
                    profiles: model.catalog.profiles, research: model.catalog.research)
                ComparisonSections(comparison: comparison, firstLabel: "Первый", secondLabel: "Второй")
            }
        }.carrierScreen().navigationTitle("Сравнить профили").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } })) {
            ProfileChooser { profile in
                if choosing == 1 { first = profile } else { second = profile }
                choosing = nil
            }
        }
    }
    private func choice(_ title: String, profile: CarrierProfile?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(profile.map { $0.bundleName + " · " + $0.version } ?? "Выбрать из каталога")
                .font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

private struct ProfileChooser: View {
    let select: (CarrierProfile) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var query = ""
    @ViewState<[CarrierProfile]> private var profiles = []
    var body: some View {
        NavigationStack {
            List {
                ForEach(profiles.filter { ProfileSearch.matches($0, query: query, research: model.catalog.research) }) { profile in
                    Button { select(profile) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.displayName).foregroundStyle(.primary)
                            Text(profile.bundleName + " · " + profile.version).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }.carrierScreen().navigationTitle("Выбрать профиль")
                .searchable(text: $query, prompt: "Название, версия или оператор")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
                .task { profiles = model.catalog.available(for: model.device) }
        }
    }
}

struct OperatorFilterPicker: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("profiles.russianOperator") private var manual = RussianOperator.all.rawValue
    @AppStorage("profiles.operatorAutomatic") private var automatic = true
    var body: some View {
        Picker("Оператор", selection: Binding(get: { automatic ? "automatic" : manual }, set: { value in
            automatic = value == "automatic"
            if !automatic { manual = value }
        })) {
            Text(model.inferredOperator.map { "По SIM: " + $0.title } ?? "По SIM: не определён").tag("automatic")
            ForEach(RussianOperator.allCases) { Text($0.title).tag($0.rawValue) }
        }
        if automatic && model.inferredOperator == nil {
            Text("Показаны все операторы РФ. Можно выбрать оператора вручную.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
